import Darwin
import Foundation

/// Refresh-driven, opt-in credit consumption with durable per-account/card deduplication.
/// All ledger access is serialized by one lock; RPC work uses the store's existing serial queue.
final class ResetCreditAutoUseCoordinator {
  /// Largest accepted integer-minute lead, allowing up to one year without arithmetic overflow.
  static let maximumLeadMinutes = 525_600

  /// Dedicated diagnostics retain five approximately 5 MiB generations for user-driven testing.
  static let log = RPCFileLogger(
    filename: "reset-credit-auto-use.log", maximumBytes: 5_242_880, retainedGenerations: 4
  )

  /// Protects state, configuration epochs and the final persistence/transmission boundary.
  private let lock = NSLock()
  /// Atomic application-owned ledger; contains no OAuth or ID tokens.
  private let stateURL: URL
  /// Saved opt-in, account binding, completed cards and unresolved operations.
  private var state = AutoUseState()
  /// Lifetime exclusive lock prevents competing utility instances from selecting the same card.
  private var lockDescriptor: Int32 = -1
  /// Any state corruption or durable-write failure pauses requests instead of forgetting history.
  private var storageError: String?
  /// Invalidates work queued before an off action, lead edit, account change or shutdown.
  private var configurationEpoch = 0
  /// Blocks overlapping refresh-driven selections until the current operation finishes.
  private var inFlight = false
  /// Shutdown rejects queued sends and closes the bounded active child.
  private var isShuttingDown = false
  /// Native process cleanup for the one current automatic operation.
  private var cancellation: ResetCreditConsumptionCancellation?
  /// Main-thread UI feedback, dispatched without holding the ledger lock.
  var onChange: (() -> Void)?
  /// Refreshes cards/usage after confirmed consumption; never directly selects another card.
  var onConsumed: (() -> Void)?

  /// Default-off preference, read safely by the AppKit settings controller.
  var isEnabled: Bool { synchronized { state.enabled } }
  /// Whole-minute setting, independent of the integer-hour notification reminders.
  var leadMinutes: Int { synchronized { state.leadMinutes } }
  /// Storage/instance failures disable the switch; ordinary RPC failures remain inspectable.
  var isAvailable: Bool { synchronized { storageError == nil && !isShuttingDown } }
  /// Settings feedback includes the most recent confirmed result across application restarts.
  var statusText: String {
    synchronized {
      if let storageError { return storageError }
      let prefix = state.enabled ? "" : "自动使用已关闭。"
      return prefix + state.notice + (state.lastCompletion.map { "\n\($0)" } ?? "")
    }
  }

  /// Loads and validates the exclusive ledger without launching any child or consuming a card.
  /// Pending operations remain pending after restart; a missing file starts with automation off.
  init() {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexQuota", isDirectory: true)
    stateURL = directory.appendingPathComponent("reset-credit-auto-use.json")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
      )
      lockDescriptor = open(
        directory.appendingPathComponent("reset-credit-auto-use.lock").path,
        O_CREAT | O_RDWR | O_CLOEXEC, 0o600
      )
      guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw CodexQuotaError.transport("另一个 Codex Quota 实例正在管理自动使用")
      }
      if FileManager.default.fileExists(atPath: stateURL.path) {
        let data = try Data(contentsOf: stateURL)
        let loaded = try JSONDecoder().decode(AutoUseState.self, from: data)
        guard loaded.version == 1, (1...Self.maximumLeadMinutes).contains(loaded.leadMinutes),
          !loaded.enabled
            || (loaded.accountKey?.isEmpty == false && loaded.authPath?.isEmpty == false),
          loaded.records.allSatisfy({ key, record in
            key == Self.recordKey(accountKey: record.accountKey, creditID: record.creditID)
              && !record.creditID.isEmpty && !record.idempotencyKey.isEmpty
              && record.attempts >= 0 && record.expiresAt.timeIntervalSince1970.isFinite
          }),
          Dictionary(grouping: loaded.records.values.filter { $0.phase == .pending },
            by: { $0.accountKey }).values.allSatisfy({ $0.count <= 1 })
        else { throw CodexQuotaError.transport("自动使用记录版本或内容不兼容") }
        state = loaded
      }
      logEvent("ledger_loaded")
    } catch {
      storageError = "自动使用暂不可用：\(error.localizedDescription)"
      logEvent("ledger_unavailable", error: error)
    }
  }

  /// Releases the lifetime lock after the application has stopped its automatic work.
  deinit {
    cancellation?.cancel()
    if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
  }

  /// Binds an explicit opt-in to the current user/workspace/path without consuming cached cards.
  /// Disabling preserves all completed and uncertain operations; a later enable can reconcile them.
  func setEnabled(_ enabled: Bool, auth: CodexAuth?) throws {
    try synchronized {
      try requireStorage()
      if enabled {
        guard !inFlight else { throw CodexQuotaError.transport("正在核对使用结果，请稍后开启") }
        guard let auth else { throw CodexQuotaError.notSignedIn }
        let identity = try CodexAuthStore().autoUseIdentity(for: auth)
        state.accountKey = identity.key
        state.authPath = identity.authPath
      }
      configurationEpoch += 1
      state.enabled = enabled
      state.notice = enabled
        ? "已开启，等待下一次重置卡刷新"
        : (inFlight ? "已停止后续提交，正在核对已提交结果" : "可按分钟设置到期前的自动使用时间")
      try persist()
      logEvent("settings_enabled_changed")
      notifyChange()
    }
  }

  /// Saves an exact integer-minute threshold and invalidates work queued under the old threshold.
  /// History and unresolved idempotency keys survive all setting edits.
  func setLeadMinutes(_ minutes: Int) throws {
    try synchronized {
      try requireStorage()
      let bounded = min(Self.maximumLeadMinutes, max(1, minutes))
      guard bounded != state.leadMinutes else { return }
      configurationEpoch += 1
      state.leadMinutes = bounded
      try persist()
      logEvent("settings_lead_changed")
      notifyChange()
    }
  }

  /// Exposes failed authentication/query refreshes without treating cached cards as new evidence.
  /// No consuming operation is selected here; normal refresh success resumes the checks.
  func reportRefreshFailure(_ error: Error) {
    synchronized {
      guard state.enabled, storageError == nil, !isShuttingDown else { return }
      state.notice = "重置卡刷新失败，自动使用已暂停：\(error.localizedDescription)"
      logEvent("credit_refresh_failed", error: error)
      notifyChange()
    }
  }

  /// Checks only a successful refresh, selects at most one earliest-expiring card, and dispatches it.
  /// An unresolved request takes priority over all new cards and retains its original idempotency key.
  func observe(
    snapshot: ResetCreditsSnapshot, auth: CodexAuth,
    client: CodexAppServerClient, queue: DispatchQueue
  ) {
    synchronized {
      guard state.enabled, storageError == nil, !isShuttingDown else {
        logEvent("refresh_skipped", fields: ["reason": "disabled_or_unavailable"])
        return
      }
      guard !inFlight else {
        logEvent("refresh_skipped", fields: ["reason": "operation_in_flight"])
        return
      }
      do {
        let identity = try CodexAuthStore().autoUseIdentity(for: auth)
        guard identity.key == state.accountKey, identity.authPath == state.authPath else {
          try pauseForAccountChange()
          return
        }
        let now = Date()
        let pending = state.records.values.first {
          $0.accountKey == identity.key && $0.phase == .pending
        }
        var selected: AutoUseRecord?
        var decisions: [[String: Any]] = []
        if let pending {
          selected = pending
        } else {
          for card in snapshot.items.sorted(by: {
            ($0.expiresAt ?? .distantFuture, $0.id) < ($1.expiresAt ?? .distantFuture, $1.id)
          }) {
            let key = Self.recordKey(accountKey: identity.key, creditID: card.id)
            let existing = state.records[key]
            let reason: String
            if snapshot.availableCount <= 0 || card.status != "available" {
              reason = "unavailable"
            } else if existing?.phase == .used || existing?.phase == .unavailable {
              reason = "already_terminal"
            } else if let expiresAt = card.expiresAt {
              let remaining = expiresAt.timeIntervalSince(now)
              if remaining <= 0 {
                reason = "expired"
              } else if remaining > TimeInterval(state.leadMinutes * 60) {
                reason = "not_due"
              } else if selected != nil {
                reason = "one_card_per_refresh"
              } else {
                // A nothingToReset reply definitively ended the old attempt, so a new
                // logical attempt may have a new UUID. Prepared retries keep their UUID.
                var record = existing ?? AutoUseRecord(
                  accountKey: identity.key, creditID: card.id, title: card.title,
                  expiresAt: expiresAt
                )
                if record.phase == .waiting {
                  record.idempotencyKey = UUID().uuidString
                  record.phase = .prepared
                  record.attempts = 0
                  record.retryAt = nil
                }
                record.title = card.title
                record.expiresAt = expiresAt
                selected = record
                reason = "selected"
              }
            } else {
              reason = "missing_expiry"
            }
            decisions.append([
              "creditID": card.id, "title": card.title, "status": card.status,
              "expiresAt": card.expiresAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
              "triggerAt": card.expiresAt.map {
                $0.addingTimeInterval(-TimeInterval(state.leadMinutes * 60))
                  .timeIntervalSince1970 as Any
              } ?? NSNull(),
              "remainingSeconds": card.expiresAt.map { $0.timeIntervalSince(now) as Any } ?? NSNull(),
              "reason": reason,
            ])
          }
        }
        logEvent("refresh_checked", fields: [
          "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970,
          "availableCount": snapshot.availableCount, "accountKey": identity.key,
          "decisions": decisions, "reconciling": pending != nil,
        ])
        guard let record = selected else {
          state.notice = "等待有有效期的可用重置卡进入提前 \(state.leadMinutes) 分钟范围"
          notifyChange()
          return
        }
        if let retryAt = record.retryAt, retryAt > now {
          state.notice = "上次结果待核对，将在后续刷新时沿用原卡和原幂等键重试"
          logEvent("retry_deferred", record: record)
          notifyChange()
          return
        }
        let key = Self.recordKey(accountKey: identity.key, creditID: record.creditID)
        state.records[key] = record
        state.notice = pending == nil ? "正在核对即将到期的重置卡" : "正在核对上次使用结果"
        try persist()
        let epoch = configurationEpoch
        let lead = state.leadMinutes
        let token = ResetCreditConsumptionCancellation()
        cancellation = token
        inFlight = true
        logEvent(pending == nil ? "operation_prepared" : "operation_reconcile", record: record)
        notifyChange()
        queue.async { [weak self] in
          guard let self else { return }
          let result: Result<ResetCreditConsumeOutcome, Error>
          do {
            result = .success(try client.consumeResetCredit(
              auth: auth, identity: identity, creditID: record.creditID,
              idempotencyKey: record.idempotencyKey, leadMinutes: lead,
              reconciling: pending != nil, cancellation: token,
              authorizeSend: { transmit in
                try self.authorizeTransmission(
                  record: record, auth: auth, identity: identity, epoch: epoch,
                  transmit: transmit
                )
              }
            ))
          } catch {
            result = .failure(error)
          }
          self.finish(result: result, record: record)
        }
      } catch {
        state.notice = "自动使用已暂停：\(error.localizedDescription)"
        logEvent("refresh_failed", error: error)
        notifyChange()
      }
    }
  }

  /// Rejects late queued sends and cancels active local transport, retaining any pending intent.
  func shutdown() {
    let token: ResetCreditConsumptionCancellation? = synchronized {
      isShuttingDown = true
      configurationEpoch += 1
      logEvent("shutdown")
      return cancellation
    }
    token?.cancel()
  }

  /// Holds the configuration lock across the final identity check, durable pending write and send.
  /// A crash or pipe-write failure after this boundary can only retry the exact same card/key.
  private func authorizeTransmission(
    record: AutoUseRecord, auth: CodexAuth, identity: CodexAutoUseIdentity, epoch: Int,
    transmit: () throws -> Void
  ) throws {
    try synchronized {
      try requireStorage()
      guard state.enabled, configurationEpoch == epoch,
        state.accountKey == record.accountKey, state.authPath == identity.authPath
      else { throw CodexQuotaError.transport("设置已改变，取消尚未提交的自动使用") }
      let current = try CodexAuthStore().autoUseIdentity(for: auth)
      guard current.key == identity.key, current.authPath == identity.authPath else {
        try pauseForAccountChange()
        throw CodexQuotaError.transport("Codex 账号已切换")
      }
      let key = Self.recordKey(accountKey: record.accountKey, creditID: record.creditID)
      guard var durable = state.records[key],
        durable.idempotencyKey == record.idempotencyKey,
        durable.phase == .prepared || durable.phase == .pending
      else { throw CodexQuotaError.transport("自动使用记录不一致，已停止提交") }
      if durable.phase != .pending {
        guard durable.expiresAt.timeIntervalSinceNow > 0,
          durable.expiresAt.timeIntervalSinceNow <= TimeInterval(state.leadMinutes * 60)
        else { throw CodexQuotaError.transport("重置卡已过期或尚未到使用时间") }
      }
      durable.phase = .pending
      durable.attempts += 1
      durable.lastAttemptAt = Date()
      durable.retryAt = nil
      state.records[key] = durable
      try persist()
      logEvent("consume_submitting", record: durable, fields: [
        "params": ["creditId": durable.creditID, "idempotencyKey": durable.idempotencyKey]
      ])
      try transmit()
    }
  }

  /// Records accepted results under the original account even after settings or shutdown changed.
  /// Transport/unknown-result failures preserve pending identity; only explicit nothingToReset
  /// permits a later new attempt. Success is saved before any UI/card/usage refresh is requested.
  private func finish(result: Result<ResetCreditConsumeOutcome, Error>, record: AutoUseRecord) {
    synchronized {
      inFlight = false
      cancellation = nil
      let key = Self.recordKey(accountKey: record.accountKey, creditID: record.creditID)
      guard var durable = state.records[key],
        durable.idempotencyKey == record.idempotencyKey
      else {
        storageError = "自动使用结果与本地记录不一致，已暂停"
        logEvent("result_record_mismatch", record: record)
        notifyChange()
        return
      }
      var consumed = false
      switch result {
      case .success(let outcome):
        durable.lastOutcome = outcome.rawValue
        durable.lastError = nil
        durable.retryAt = nil
        switch outcome {
        case .reset, .alreadyRedeemed:
          durable.phase = .used
          consumed = true
          state.notice = outcome == .reset ? "重置卡已自动使用" : "已确认该重置卡使用成功"
          state.lastCompletion = "\(state.notice)：\(durable.title)，\(DisplayFormatter.exact(Date()))"
        case .nothingToReset:
          durable.phase = .waiting
          state.notice = "服务返回无需重置，卡片未使用；下次成功刷新再检查"
        case .noCredit:
          durable.phase = .unavailable
          state.notice = "服务返回该卡不可用，已停止对此卡提交"
        }
        logEvent("consume_result", record: durable, fields: ["outcome": outcome.rawValue])
      case .failure(let error):
        durable.lastError = error.localizedDescription
        // Backoff is checked only during existing refreshes; it never creates another timer.
        let delay = min(900.0, 60.0 * pow(2.0, Double(min(4, max(0, durable.attempts - 1)))))
        durable.retryAt = Date().addingTimeInterval(delay)
        state.notice = durable.phase == .pending
          ? "使用结果待核对，将沿用原卡和原幂等键；\(error.localizedDescription)"
          : "尚未提交使用请求，等待后续刷新；\(error.localizedDescription)"
        if let failure = error as? CodexQuotaError,
          case .rpc(let code, _) = failure, code == -32601 || code == -32602
        {
          state.enabled = false
          configurationEpoch += 1
          state.notice = "当前 Codex 不支持自动使用接口，请更新 CLI 后重新开启；RPC \(code)"
        }
        logEvent("consume_failed", record: durable, error: error)
      }
      state.records[key] = durable
      do {
        try persist()
      } catch {
        // A successful response remains in memory and in the diagnostics; the on-disk
        // pending operation keeps its old UUID, so recovery can safely reconcile it.
        logEvent("result_persist_failed", record: durable, error: error)
        consumed = false
      }
      notifyChange()
      if consumed, !isShuttingDown {
        DispatchQueue.main.async { [weak self] in self?.onConsumed?() }
      }
    }
  }

  /// Disables the old binding while retaining its card history and any unresolved operation.
  /// Called only while holding the coordinator lock.
  private func pauseForAccountChange() throws {
    state.enabled = false
    configurationEpoch += 1
    state.notice = "Codex 登录账号已切换，请为当前账号重新开启自动使用"
    try persist()
    logEvent("account_changed")
    notifyChange()
  }

  /// Rejects state writes/submissions after ledger failure or application shutdown.
  /// Result persistence deliberately bypasses this shutdown check to retain accepted outcomes.
  private func requireStorage() throws {
    if let storageError { throw CodexQuotaError.transport(storageError) }
    if isShuttingDown { throw CodexQuotaError.transport("软件正在退出") }
  }

  /// Writes a private temporary file, fsyncs it, atomically renames it and fsyncs the directory.
  /// Pending intent must reach durable storage before any consuming bytes are written.
  /// Caller holds the coordinator lock; any failure makes further requests unavailable.
  private func persist() throws {
    let temporary = stateURL.deletingLastPathComponent()
      .appendingPathComponent(".reset-credit-auto-use-\(UUID().uuidString).tmp")
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(state)
      let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw POSIXError(.EIO) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
      }
      try handle.write(contentsOf: data)
      try handle.synchronize()
      guard rename(temporary.path, stateURL.path) == 0 else { throw POSIXError(.EIO) }
      let directory = open(stateURL.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
      guard directory >= 0 else { throw POSIXError(.EIO) }
      defer { Darwin.close(directory) }
      guard fsync(directory) == 0 else { throw POSIXError(.EIO) }
    } catch {
      storageError = "无法保存自动使用记录，已暂停提交：\(error.localizedDescription)"
      notifyChange()
      throw error
    }
  }

  /// Serializes any state access; nested synchronized calls are intentionally avoided.
  private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Provides stable per-user/workspace/card deduplication without including mutable expiry time.
  private static func recordKey(accountKey: String, creditID: String) -> String {
    "\(accountKey):\(creditID)"
  }

  /// Enqueues UI feedback on the main queue after the current ledger operation unlocks.
  private func notifyChange() {
    DispatchQueue.main.async { [weak self] in self?.onChange?() }
  }

  /// Records decision/configuration/operation evidence as complete JSON without login credentials.
  /// All call sites hold the state lock except initialization before the object is published.
  private func logEvent(
    _ event: String, record: AutoUseRecord? = nil, fields: [String: Any] = [:],
    error: Error? = nil
  ) {
    var payload = fields
    payload["event"] = event
    payload["enabled"] = state.enabled
    payload["leadMinutes"] = state.leadMinutes
    payload["accountKey"] = state.accountKey.map { $0 as Any } ?? NSNull()
    payload["authPath"] = state.authPath.map { $0 as Any } ?? NSNull()
    payload["recordCount"] = state.records.count
    payload["configurationEpoch"] = configurationEpoch
    payload["inFlight"] = inFlight
    payload["notice"] = state.notice
    payload["error"] = error.map { $0.localizedDescription as Any } ?? NSNull()
    if let record, let data = try? JSONEncoder().encode(record),
      let object = try? JSONSerialization.jsonObject(with: data)
    {
      payload["operation"] = object
    }
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    {
      Self.log.write(kind: "auto_use", payload: json)
    }
  }
}

/// Atomic versioned ledger; terminal cards are retained across restarts, edits and account switches.
private struct AutoUseState: Codable {
  /// Schema version is explicitly validated before any automatic operation.
  var version = 1
  /// New installations and existing installations without this ledger default to off.
  var enabled = false
  /// Positive whole-minute threshold; the initial value is ten minutes before expiry.
  var leadMinutes = 10
  /// Stable user/workspace digest, shared by history even when the user moves the auth file.
  var accountKey: String?
  /// Canonical authentication path for this opt-in; changing it requires explicitly enabling again.
  var authPath: String?
  /// Records keyed by stable account/card identity; unresolved operations retain their old UUID.
  var records: [String: AutoUseRecord] = [:]
  /// Current setting/operation feedback without retaining historical conversation text.
  var notice = "可按分钟设置到期前的自动使用时间"
  /// Latest confirmed card result shown independently of the next refresh's waiting state.
  var lastCompletion: String?
}

/// Consumption state distinguishes definite non-submission from uncertain remote completion.
private enum AutoUsePhase: String, Codable {
  /// Intent saved but no consuming request has crossed the durable transmission boundary.
  case prepared
  /// Request may have reached the backend; only the original UUID may be retried.
  case pending
  /// Explicit nothingToReset confirmed no consumption; a later attempt may use a new UUID.
  case waiting
  /// Confirmed reset/alreadyRedeemed; permanently suppress this account/card identity.
  case used
  /// Explicit noCredit; suppress further attempts on this account/card identity.
  case unavailable
}

/// One durable card operation, including the exact identity required for idempotent reconciliation.
private struct AutoUseRecord: Codable {
  /// Stable user/workspace digest captured at selection, never reassigned on account changes.
  let accountKey: String
  /// Exact backend card ID; every consuming request explicitly supplies this value.
  let creditID: String
  /// Last observed title displayed in settings after successful consumption.
  var title: String
  /// Last observed expiry; missing-expiry cards are never selected for a new operation.
  var expiresAt: Date
  /// UUID reused after every ambiguous error, shutdown or restart of this logical operation.
  var idempotencyKey = UUID().uuidString
  /// Last durable operation phase; pending is written before the request reaches the pipe.
  var phase: AutoUsePhase = .prepared
  /// Number of actual transmission attempts, used only for bounded refresh-driven backoff.
  var attempts = 0
  /// Last transmission time for log correlation and later user-driven diagnosis.
  var lastAttemptAt: Date?
  /// Earliest retry time, observed only by the existing successful-credit-refresh path.
  var retryAt: Date?
  /// Latest recognized backend outcome, preserved separately from local refresh failures.
  var lastOutcome: String?
  /// Latest transport/protocol failure, retained for diagnosis without credentials.
  var lastError: String?
}
