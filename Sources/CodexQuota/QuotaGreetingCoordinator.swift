import Darwin
import Foundation

/// Owns account-bound reset observation and durable background execution independently of notifications.
/// State is main-thread confined; model calls run on a serial worker and report confirmed completion.
final class QuotaGreetingCoordinator {
  /// Three bounded retries apply only to failures definitely preceding model submission.
  private static let retryDelays: [TimeInterval] = [30, 120, 600]
  /// Application-owned atomic ledger, separate from Codex databases and authentication material.
  private let stateURL: URL
  /// Executes at most one manual or automatic model request at a time without blocking AppKit.
  private let worker = DispatchQueue(label: "com.local.CodexQuota.greetings", qos: .utility)
  /// Completion-based runner; injectable so migration and reset cases can be verified in isolation.
  private let client: CodexGreetingExecuting
  /// Switch, account binding, quota baselines and execution history saved as one snapshot.
  private var state = GreetingState()
  /// Lifetime lock prevents two utility instances from consuming the same reset event.
  private var lockDescriptor: Int32 = -1
  /// Storage failures disable sending instead of permitting unrecorded duplicate submissions.
  private var storageError: String?
  /// Requests a fresh quota snapshot at the earliest permitted retry time.
  private var retryWork: DispatchWorkItem?
  /// Thread-safe handle used when the switch is disabled or the application exits.
  private var cancellation: CodexExecutionCancellation?
  /// Blocks late callbacks and launches once application-exit cleanup has begun.
  private var isShuttingDown = false
  /// True while either a manual or automatic background execution is in progress.
  private(set) var isSending = false
  /// Refreshes settings and other UI after state changes on the main thread.
  var onChange: (() -> Void)?
  /// Obtains a new authenticated snapshot before retrying a definitely unsubmitted request.
  var onNeedsFreshSnapshot: (() -> Void)?

  /// Preserves the user's opt-in across migration; new installations remain disabled by default.
  var isEnabled: Bool { state.enabled }
  /// Indicates that this process owns a usable exclusive ledger and can execute requests.
  var isAvailable: Bool { storageError == nil && !isShuttingDown }
  /// Requires explicit acknowledgement before continuing after an ambiguous remote outcome.
  var needsReview: Bool { state.job?.phase == .uncertain }
  /// A manual test cannot overwrite a pending automatic job or an unreviewed execution.
  var canSendTest: Bool {
    isAvailable && !isSending && !needsReview && state.job?.phase != .pending
  }
  /// Combines actual completion time, final response and measured token usage for the settings UI.
  var statusText: String {
    if let storageError { return storageError }
    var text = state.enabled ? state.notice : "自动问候已关闭。\(state.notice)"
    if let result = state.lastResult {
      text += "\n上次完成：\(DisplayFormatter.exact(result.completedAt))"
      text += "\n回复：\(result.reply.prefix(100))"
      text +=
        "\n用量：输入 \(result.usage["input_tokens"] ?? 0)，输出 \(result.usage["output_tokens"] ?? 0) tokens"
    }
    return text
  }

  /// Locks and loads the ledger, backing up version 1 before an atomic migration without historical replay.
  /// An optional private directory and runner allow verification without touching the installed app's data.
  init(
    fileManager: FileManager = .default, stateDirectory: URL? = nil,
    client: CodexGreetingExecuting = CodexExecClient()
  ) {
    self.client = client
    let directory =
      stateDirectory
      ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexQuota", isDirectory: true)
    stateURL = directory.appendingPathComponent("greetings.json")
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      lockDescriptor = open(
        directory.appendingPathComponent("greetings.lock").path, O_CREAT | O_RDWR, 0o600)
      // A model subprocess must not retain the utility's lifetime lock after its parent exits.
      guard lockDescriptor >= 0, fcntl(lockDescriptor, F_SETFD, FD_CLOEXEC) == 0,
        flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
      else {
        throw CodexQuotaError.transport("另一个额度小工具正在处理自动问候")
      }
      if fileManager.fileExists(atPath: stateURL.path) {
        let data = try Data(contentsOf: stateURL)
        let version = try JSONDecoder().decode(GreetingLedgerVersion.self, from: data).version
        if version == 2 {
          state = try JSONDecoder().decode(GreetingState.self, from: data)
        } else if version == 1 {
          let legacy = try JSONDecoder().decode(LegacyGreetingState.self, from: data)
          let backup = directory.appendingPathComponent("greetings-v1-\(UUID().uuidString).json")
          try data.write(to: backup, options: .atomic)
          try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
          state.enabled = legacy.enabled
          state.accountKey = legacy.accountKey
          state.authPath = legacy.authPath
          state.baselines = legacy.baselines
          state.legacyQueuedAt = legacy.lastQueuedAt
          state.legacyReceipt = legacy.lastReceipt
          state.notice = "已切换为后台问候，等待下一次额度重置；旧消息不补发"
          if ["sending", "uncertain"].contains(legacy.job?.phase ?? "") {
            state.job = GreetingJob(cycles: legacy.job?.cycles ?? [], phase: .uncertain)
            state.notice = "旧版提交结果待核实；查看日志后可跳过本次，继续后续重置"
          }
          try persist()
        } else {
          throw CodexQuotaError.transport("自动问候记录版本不兼容")
        }
      }
      if state.job?.phase == .running {
        state.job?.phase = .uncertain
        state.notice = "上次后台执行中断，结果待核实；请查看执行日志"
        try persist()
      } else if state.enabled, !needsReview, !state.deferredCycles.isEmpty {
        state.job = GreetingJob(cycles: state.deferredCycles)
        state.deferredCycles = []
        state.notice = "已有确认的重置，等待最新额度查询后执行"
        try persist()
      }
    } catch {
      storageError = "自动问候暂不可用：\(error.localizedDescription)"
    }
  }

  /// Cancels any remaining child and releases the instance lock without touching Codex chat storage.
  deinit {
    retryWork?.cancel()
    cancellation?.cancel(waitForExit: true)
    if lockDescriptor >= 0 { close(lockDescriptor) }
  }

  /// Enables observation from a fresh baseline; disabling cancels retries and any active local process.
  /// Already submitted remote work cannot be withdrawn, so cancellation may still require review.
  func setEnabled(_ enabled: Bool, auth: CodexAuth?) throws {
    try requireStorage()
    if enabled {
      guard !isSending else { throw CodexQuotaError.transport("正在执行，请稍后开启") }
      guard !needsReview else { throw CodexQuotaError.transport("请先查看执行日志并跳过待核实任务") }
      guard let auth else { throw CodexQuotaError.notSignedIn }
      state.accountKey = QuotaResetDetector.accountKey(auth.accountID)
      state.authPath = auth.authPath
    }
    retryWork?.cancel()
    state.enabled = enabled
    state.baselines = [:]
    state.deferredCycles = []
    if !isSending && !needsReview { state.job = nil }
    if enabled {
      state.notice = "已开启，等待下一次确认的额度重置"
    } else if isSending {
      cancellation?.cancel()
      state.notice = "正在停止后台执行；远端请求可能已产生用量"
    } else if !needsReview {
      state.notice = "后续额度重置不会自动发送"
    }
    try persist()
    onChange?()
  }

  /// Skips an ambiguous request without retrying it and seeds a new baseline for future resets.
  func acknowledgeReview() throws {
    try requireStorage()
    guard needsReview, !isSending else { return }
    state.job = nil
    state.baselines = [:]
    state.deferredCycles = []
    state.notice = "已跳过本次，从之后检测到的额度重置继续"
    try persist()
    onChange?()
  }

  /// Records confirmed quota-cycle changes atomically and merges simultaneous window resets into one job.
  func observe(snapshot: QuotaSnapshot, auth: CodexAuth) {
    guard isAvailable, state.enabled else { return }
    do {
      guard state.accountKey == QuotaResetDetector.accountKey(auth.accountID),
        state.authPath == auth.authPath
      else {
        try setEnabled(false, auth: nil)
        state.notice = "Codex 账号已切换，请重新开启自动问候"
        try persist()
        onChange?()
        return
      }
      let windows = [snapshot.fiveHour, snapshot.sevenDay].compactMap { $0 }
      guard !windows.isEmpty else { return }
      var cycles: [String] = []
      for window in windows {
        let key = window.kind == .fiveHour ? "fiveHour" : "sevenDay"
        if let previous = state.baselines[key],
          window.resetsAt.timeIntervalSince(previous.resetsAt) < -QuotaResetDetector
            .timestampTolerance
        {
          // Reject timestamp regressions so stale responses cannot re-arm a completed cycle.
          continue
        }
        if let previous = state.baselines[key],
          QuotaResetDetector.didReset(
            previousReset: previous.resetsAt, previousRemaining: previous.remaining,
            current: window, fetchedAt: snapshot.fetchedAt)
        {
          cycles.append("\(key):\(window.resetsAt.timeIntervalSince1970)")
        }
        state.baselines[key] = GreetingBaseline(
          resetsAt: window.resetsAt, remaining: window.remainingPercent)
      }
      if !cycles.isEmpty && !needsReview {
        if isSending {
          state.deferredCycles = Array(Set(state.deferredCycles + cycles)).sorted()
        } else {
          // Recovery after a long absence handles only the latest observation, never every missed cycle.
          state.job = GreetingJob(cycles: cycles)
          state.notice = "已确认额度重置，等待后台执行"
        }
      }
      try persist()
      guard let job = state.job, job.phase == .pending, !isSending else {
        onChange?()
        return
      }
      guard windows.allSatisfy({ $0.remainingPercent > 0 }),
        state.baselines.values.allSatisfy({ $0.remaining > 0 })
      else {
        state.notice = "已检测到重置，等待其他额度窗口恢复后执行"
        try persist()
        onChange?()
        return
      }
      if let retryAt = job.retryAt, retryAt > Date() {
        scheduleFreshSnapshot(after: retryAt.timeIntervalSinceNow)
        return
      }
      try submit(auth: auth, job: job)
    } catch {
      onChange?()
    }
  }

  /// Executes one explicit test without consuming the automatic cycle baselines, even with opt-in off.
  func sendTest(auth: CodexAuth) throws {
    try requireStorage()
    guard canSendTest else {
      throw CodexQuotaError.transport("请等待当前任务结束，或先跳过待核实任务")
    }
    try submit(auth: auth, job: GreetingJob(cycles: [], isTest: true))
  }

  /// Persists an interrupted state before bounded child cleanup so relaunch cannot replay in-flight work.
  func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    retryWork?.cancel()
    if isSending {
      state.job?.phase = .uncertain
      state.notice = "退出时后台执行中断，结果待核实；请查看执行日志"
      try? persist()
      logDelivery()
    }
    cancellation?.cancel(waitForExit: true)
  }

  /// Rejects writes and launches when storage is unsafe or application shutdown has begun.
  private func requireStorage() throws {
    if let storageError { throw CodexQuotaError.transport(storageError) }
    if isShuttingDown { throw CodexQuotaError.transport("软件正在退出") }
  }

  /// Saves configuration, baselines and phase together before a request is launched or finalized.
  private func persist() throws {
    do {
      let data = try JSONEncoder().encode(state)
      try data.write(to: stateURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    } catch {
      storageError = "无法保存自动问候记录，已暂停发送"
      throw error
    }
  }

  /// Durably marks the job running before dispatch so crashes cannot automatically duplicate requests.
  private func submit(auth: CodexAuth, job: GreetingJob) throws {
    try requireStorage()
    guard !isSending else { throw CodexQuotaError.transport("正在执行，请稍候") }
    var running = job
    running.phase = .running
    running.attempts += 1
    running.retryAt = nil
    state.job = running
    state.notice = job.isTest ? "正在后台执行测试问候" : "正在后台执行问候"
    try persist()
    let token = CodexExecutionCancellation()
    cancellation = token
    isSending = true
    logDelivery()
    onChange?()
    worker.async { [weak self] in
      guard let self else { return }
      let result: Result<CodexGreetingResult, Error>
      do { result = .success(try self.client.send(auth: auth, cancellation: token)) } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async {
        self.finish(result: result, jobID: job.id)
      }
    }
  }

  /// Records actual completion, safe pre-submission retries or an uncertain result without blind replay.
  private func finish(result: Result<CodexGreetingResult, Error>, jobID: String) {
    guard !isShuttingDown else { return }
    isSending = false
    cancellation = nil
    guard var job = state.job, job.id == jobID else { return }
    switch result {
    case .success(let completed):
      state.lastResult = completed
      state.notice = job.isTest ? "后台测试问候已完成，已产生模型用量" : "后台问候已完成，已产生模型用量"
      job.phase = .completed
    case .failure(let error):
      let failure = error as? CodexExecutionFailure
      state.notice = error.localizedDescription
      if failure?.isUncertain != false {
        job.phase = .uncertain
      } else if failure?.isRetryable == true, !job.isTest, state.enabled,
        job.attempts <= Self.retryDelays.count
      {
        let delay = Self.retryDelays[job.attempts - 1]
        job.phase = .pending
        job.retryAt = Date().addingTimeInterval(delay)
        state.notice = "尚未提交，将稍后重试：\(error.localizedDescription)"
        scheduleFreshSnapshot(after: delay)
      } else {
        job.phase = .failed
      }
    }
    state.job = job
    if state.enabled, !needsReview, !state.deferredCycles.isEmpty {
      state.job = GreetingJob(cycles: state.deferredCycles)
      state.deferredCycles = []
      state.notice += "；另一次重置等待最新额度确认"
      scheduleFreshSnapshot(after: 1)
    }
    try? persist()
    logDelivery()
    onChange?()
  }

  /// Schedules a fresh snapshot rather than executing with stale quota or after the switch is disabled.
  private func scheduleFreshSnapshot(after delay: TimeInterval) {
    let retry = DispatchWorkItem { [weak self] in
      guard let self, self.state.enabled, !self.isShuttingDown else { return }
      self.onNeedsFreshSnapshot?()
    }
    retryWork?.cancel()
    retryWork = retry
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: retry)
  }

  /// Logs the complete application-owned ledger at execution boundaries without OAuth secrets.
  private func logDelivery() {
    if let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) {
      RPCFileLogger.shared.write(kind: "greeting", payload: json)
    }
  }
}

/// Version probe prevents decoding an incompatible ledger with misleading default values.
private struct GreetingLedgerVersion: Decodable {
  /// Exact persisted schema version, checked before any migration or background execution.
  let version: Int
}

/// Version 2 ledger stores completed model evidence separately from legacy queue receipts.
private struct GreetingState: Codable {
  /// This schema uses execution completion and explicit migration from version 1.
  var version = 2
  /// User-controlled opt-in; preserved during migration and false for new installations.
  var enabled = false
  /// Opaque subscription account binding used to pause after account changes.
  var accountKey: String?
  /// Codex authentication directory binding, shared with the quota reader.
  var authPath: String?
  /// Last observed quota cycle and remaining amount for each semantic window.
  var baselines: [String: GreetingBaseline] = [:]
  /// Latest manual or automatic request; running and uncertain are never automatically replayed.
  var job: GreetingJob?
  /// New cycles observed during an active execution and merged into a single later request.
  var deferredCycles: [String] = []
  /// User-visible execution result, persisted so settings remain meaningful after relaunch.
  var notice = "开启后，在确认额度重置时后台发送“你好”"
  /// Last confirmed model completion, including response, usage and diagnostic execution identifier.
  var lastResult: CodexGreetingResult?
  /// Historical version 1 acceptance time, never presented as completed model execution.
  var legacyQueuedAt: Date?
  /// Historical version 1 receipt retained for diagnostics only, never resubmitted.
  var legacyReceipt: String?
}

/// Read-only subset of version 1; legacy pending jobs are intentionally not replayed during migration.
private struct LegacyGreetingState: Decodable {
  /// Saved opt-in carried into the independent background executor.
  let enabled: Bool
  /// Existing opaque account binding, preserved with the observed baselines.
  let accountKey: String?
  /// Existing authentication location, preserved to prevent cross-account sends.
  let authPath: String?
  /// Previously observed cycles, retained so upgrading cannot re-detect an old reset.
  let baselines: [String: GreetingBaseline]
  /// Only its ambiguous phases require user review; queued never means completed.
  let job: LegacyGreetingJob?
  /// Optional historical acceptance timestamp retained separately from new completion results.
  let lastQueuedAt: Date?
  /// Optional historical queue receipt retained as diagnostic evidence.
  let lastReceipt: String?
}

/// Legacy delivery subset sufficient to quarantine ambiguous submissions without replaying them.
private struct LegacyGreetingJob: Decodable {
  /// Old phase string; sending and uncertain require acknowledgement before future execution.
  let phase: String
  /// Cycle identifiers are retained only when an old request needs review.
  let cycles: [String]
}

/// Persisted reset evidence used by the shared detector across application restarts.
private struct GreetingBaseline: Codable {
  /// Last backend reset timestamp, protected against stale timestamp regressions.
  let resetsAt: Date
  /// Last observed remaining quota percentage used as supplementary reset evidence.
  let remaining: Double
}

/// Execution phases distinguish definite completion from unknown remote outcomes.
private enum GreetingPhase: String, Codable {
  /// A confirmed reset has not yet launched a model request.
  case pending
  /// A background request is active; recovery must not replay this phase.
  case running
  /// Both successful process exit and a nonempty model completion with usage were confirmed.
  case completed
  /// Known pre-submission error exhausted retry eligibility or requires configuration repair.
  case failed
  /// Remote completion cannot be established; an explicit skip permits later cycles to continue.
  case uncertain
}

/// Durable request identity links asynchronous results with the correct automatic or manual job.
private struct GreetingJob: Codable {
  /// Local request identity used to reject unrelated or late worker results.
  var id = UUID().uuidString
  /// Quota-cycle identities covered by this request; manual tests use an empty list.
  let cycles: [String]
  /// True for explicit tests, which never alter baselines or automatically retry.
  var isTest = false
  /// Last phase persisted before execution or after completion classification.
  var phase: GreetingPhase = .pending
  /// Number of launch attempts, including only this job and its permitted pre-submission retries.
  var attempts = 0
  /// Earliest retry instant, always followed by a fresh successful quota observation.
  var retryAt: Date?
}
