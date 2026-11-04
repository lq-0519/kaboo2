import Darwin
import Foundation

/// Refresh-driven, opt-in credit consumption with durable per-account/card deduplication.
/// All ledger access is serialized by one lock; RPC work uses the store's existing serial queue.
final class ResetCreditAutoUseCoordinator {
  /// Largest accepted integer-minute lead, allowing up to one year without arithmetic overflow.
  static let maximumLeadMinutes = 525_600

  /// Tolerance for ordinary timer scheduling latency; any later fire is recorded as missed.
  /// The user explicitly chose not to backfill a schedule that was skipped by sleep or app exit.
  static let scheduleExecutionTolerance: TimeInterval = 60

  /// Short delay between due-time credit refresh retries while still inside the tolerance window.
  private static let scheduleRefreshRetryDelay: TimeInterval = 20

  /// Maximum fresh credit queries attempted for one scheduled trigger.
  private static let maximumScheduleRefreshAttempts = 3

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
  /// Diagnostic revision across both modes, account changes and shutdown.
  /// Per-mode epochs below independently authorize queued work after setting edits.
  private var configurationEpoch = 0
  /// Invalidates only expiry-lead work after its switch or minutes change.
  /// Fixed-time setting edits leave this value unchanged so the two switches remain independent.
  private var leadConfigurationEpoch = 0
  /// Invalidates only fixed-time work after its target or switch changes.
  /// Lead-setting edits do not cancel a scheduled submission that is still being prepared.
  private var scheduleConfigurationEpoch = 0
  /// Blocks overlapping refresh-driven selections until the current operation finishes.
  private var inFlight = false
  /// Shutdown rejects queued sends and closes the bounded active child.
  private var isShuttingDown = false
  /// Native process cleanup for the one current automatic operation.
  private var cancellation: ResetCreditConsumptionCancellation?
  /// One-shot wall-clock timer for the optional fixed-time trigger; nil while no target exists.
  private var scheduleTimer: Timer?
  /// Fresh credit refresh attempts already spent on the current scheduled trigger.
  private var scheduleAttempts = 0
  /// Wall-clock instant when the current target was armed, used to detect sleep across the target.
  private var scheduleArmedAt: Date?
  /// Monotonic uptime when armed; uptime excludes sleep on macOS and detects skipped wall time.
  private var scheduleArmedUptime: TimeInterval?
  /// Main-thread callback owned by the store to run one fresh credit refresh at the target time.
  var onScheduleDue: (() -> Void)?
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
  /// Armed one-shot target; nil means the fixed-time trigger is off.
  var scheduledAt: Date? { synchronized { state.scheduledAt } }
  /// Fixed-time feedback showing the armed target, the last completion or the missed reason.
  var scheduledStatusText: String {
    synchronized {
      if let storageError { return storageError }
      if let target = state.scheduledAt {
        return "已设定：\(DisplayFormatter.exact(target)) 使用当时最早到期的一张卡。"
      }
      return state.scheduledLastResult ?? "尚未设置定时使用。"
    }
  }
  /// Settings feedback includes the most recent confirmed result across application restarts.
  var statusText: String {
    synchronized {
      if let storageError { return storageError }
      let prefix = state.enabled ? "" : "到期前自动使用已关闭。"
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
        guard loaded.version == 1 || loaded.version == 2,
          (1...Self.maximumLeadMinutes).contains(loaded.leadMinutes),
          loaded.scheduledAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
          !loaded.enabled && loaded.scheduledAt == nil
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
      // A target that passed while the app was not running is never backfilled by design.
      if let target = state.scheduledAt, Date() >= target {
        state.scheduledAt = nil
        state.scheduledLastResult = "已错过 \(DisplayFormatter.exact(target)) 的定时使用（应用当时未运行）。"
        do { try persist() } catch {}
        logEvent("schedule_missed", fields: [
          "scheduledAt": target.timeIntervalSince1970, "reason": "app_not_running",
        ])
      }
      armScheduleTimer()
    } catch {
      storageError = "自动使用暂不可用：\(error.localizedDescription)"
      logEvent("ledger_unavailable", error: error)
    }
  }

  /// Releases the lifetime lock after the application has stopped its automatic work.
  deinit {
    scheduleTimer?.invalidate()
    cancellation?.cancel()
    if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
  }

  /// Binds the expiry-lead switch to the current login without changing a fixed-time target.
  /// Disabling invalidates only unsent lead work and preserves completed/uncertain card history.
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
      leadConfigurationEpoch += 1
      state.enabled = enabled
      state.notice = enabled
        ? "到期前自动使用已开启，等待下一次重置卡刷新"
        : (inFlight ? "已停止到期前的后续提交，正在核对使用结果" : "可按分钟设置到期前的自动使用时间")
      try persist()
      logEvent("settings_enabled_changed", fields: ["triggerMode": "expiry_lead"])
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
      leadConfigurationEpoch += 1
      state.leadMinutes = bounded
      try persist()
      logEvent("settings_lead_changed", fields: ["triggerMode": "expiry_lead"])
      notifyChange()
    }
  }

  /// Arms one fixed wall-clock instant for one earliest-expiring card, independent of lead mode.
  /// The target is persisted before the local timer is installed; a past instant is rejected.
  func setScheduledUse(at date: Date, auth: CodexAuth?) throws {
    try synchronized {
      try requireStorage()
      guard !inFlight else { throw CodexQuotaError.transport("正在核对使用结果，请稍后设置定时") }
      guard let auth else { throw CodexQuotaError.notSignedIn }
      let identity = try CodexAuthStore().autoUseIdentity(for: auth)
      guard date.timeIntervalSince(Date()) > Self.scheduleExecutionTolerance else {
        throw CodexQuotaError.transport("定时使用时间必须晚于当前时间")
      }
      configurationEpoch += 1
      scheduleConfigurationEpoch += 1
      state.accountKey = identity.key
      state.authPath = identity.authPath
      state.scheduledAt = date
      state.scheduledLastResult = nil
      scheduleAttempts = 0
      try persist()
      armScheduleTimer()
      logEvent("schedule_armed", fields: [
        "scheduledAt": date.timeIntervalSince1970,
        "secondsUntil": date.timeIntervalSince(Date()),
      ])
      notifyChange()
    }
  }

  /// Clears one one-shot target without touching completed or uncertain card history.
  func cancelScheduledUse() throws {
    try synchronized {
      try requireStorage()
      guard let cancelledTarget = state.scheduledAt else { return }
      configurationEpoch += 1
      scheduleConfigurationEpoch += 1
      state.scheduledAt = nil
      state.scheduledLastResult = "已取消定时使用。"
      scheduleAttempts = 0
      scheduleArmedAt = nil
      scheduleArmedUptime = nil
      scheduleTimer?.invalidate()
      scheduleTimer = nil
      try persist()
      logEvent("schedule_cancelled", fields: [
        "triggerMode": "scheduled",
        "cancelledTargetAt": cancelledTarget.timeIntervalSince1970,
      ])
      notifyChange()
    }
  }

  /// Exposes failed authentication/query refreshes without treating cached cards as new evidence.
  /// A scheduled trigger gets a few short in-window retries; anything later becomes a recorded miss.
  func reportRefreshFailure(_ error: Error, scheduledDue: Bool = false) {
    synchronized {
      guard storageError == nil, !isShuttingDown else { return }
      if scheduledDue, let target = state.scheduledAt {
        let now = Date()
        let withinWindow = now.timeIntervalSince(target) <= Self.scheduleExecutionTolerance
        if scheduleAttempts < Self.maximumScheduleRefreshAttempts, withinWindow {
          logEvent("schedule_refresh_retry", fields: [
            "scheduledAt": target.timeIntervalSince1970,
            "attempt": scheduleAttempts,
            "retryDelaySeconds": Self.scheduleRefreshRetryDelay,
          ], error: error)
          armScheduleTimer(retryDelay: Self.scheduleRefreshRetryDelay)
          notifyChange()
          return
        }
        markScheduleMissed(target: target, reason: "refresh_failed", error: error)
        return
      }
      guard state.enabled else { return }
      state.notice = "重置卡刷新失败，自动使用已暂停：\(error.localizedDescription)"
      logEvent("credit_refresh_failed", error: error)
      notifyChange()
    }
  }

  /// Checks only a successful refresh, selects at most one earliest-expiring card, and dispatches it.
  /// An unresolved request takes priority over all new cards and retains its original idempotency key.
  /// A scheduled evaluation ignores the expiry lead but still requires an unexpired card.
  func observe(
    snapshot: ResetCreditsSnapshot, auth: CodexAuth,
    client: CodexAppServerClient, queue: DispatchQueue,
    scheduledDue: Bool = false
  ) {
    synchronized {
      guard state.enabled || scheduledDue else {
        logEvent("refresh_skipped", fields: ["reason": "disabled_or_unavailable"])
        return
      }
      guard !scheduledDue || state.scheduledAt != nil else {
        logEvent("refresh_skipped", fields: ["reason": "schedule_not_armed"])
        return
      }
      guard storageError == nil, !isShuttingDown else {
        if scheduledDue, let target = state.scheduledAt {
          markScheduleMissed(target: target, reason: "unavailable")
        }
        logEvent("refresh_skipped", fields: ["reason": "disabled_or_unavailable"])
        return
      }
      guard !inFlight else {
        logEvent("refresh_skipped", fields: ["reason": "operation_in_flight"])
        if scheduledDue {
          armScheduleTimer(retryDelay: Self.scheduleRefreshRetryDelay)
        }
        return
      }
      let scheduleTarget = scheduledDue ? state.scheduledAt : nil
      do {
        let identity = try CodexAuthStore().autoUseIdentity(for: auth)
        guard identity.key == state.accountKey, identity.authPath == state.authPath else {
          try pauseForAccountChange()
          return
        }
        let now = Date()
        if scheduledDue, let target = scheduleTarget,
          now.timeIntervalSince(target) > Self.scheduleExecutionTolerance
        {
          markScheduleMissed(target: target, reason: "refresh_late")
          return
        }
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
              } else if !scheduledDue, remaining > TimeInterval(state.leadMinutes * 60) {
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
          "scheduledDue": scheduledDue,
        ])
        guard let record = selected else {
          if scheduledDue {
            state.scheduledAt = nil
            state.scheduledLastResult = "定时检查时没有可用重置卡，本次未使用。"
            scheduleTimer?.invalidate()
            scheduleTimer = nil
            try persist()
            logEvent("schedule_no_card", fields: [
              "scheduledAt": scheduleTarget?.timeIntervalSince1970 ?? NSNull(),
              "availableCount": snapshot.availableCount,
            ])
            notifyChange()
            return
          }
          state.notice = "等待有有效期的可用重置卡进入提前 \(state.leadMinutes) 分钟范围"
          notifyChange()
          return
        }
        if let retryAt = record.retryAt, retryAt > now {
          if scheduledDue {
            state.scheduledAt = nil
            state.scheduledLastResult = "上次使用结果待核对，定时未选择新卡；请等待后续核对完成。"
            scheduleTimer?.invalidate()
            scheduleTimer = nil
            try persist()
            logEvent("schedule_pending_wait", record: record)
            notifyChange()
            return
          }
          state.notice = "上次结果待核对，将在后续刷新时沿用原卡和原幂等键重试"
          logEvent("retry_deferred", record: record)
          notifyChange()
          return
        }
        let key = Self.recordKey(accountKey: identity.key, creditID: record.creditID)
        state.records[key] = record
        state.notice = pending == nil ? "正在核对即将到期的重置卡" : "正在核对上次使用结果"
        if scheduledDue {
          // Disarm inside the same durable write that records the operation, so a crash cannot refire.
          state.scheduledAt = nil
          state.scheduledLastResult = pending == nil
            ? "已于 \(DisplayFormatter.exact(now)) 触发定时使用：\(record.title)"
            : "定时触发时存在待核对操作，本次未选择新卡；正在核对原提交。"
          scheduleTimer?.invalidate()
          scheduleTimer = nil
          scheduleAttempts = 0
          scheduleArmedAt = nil
          scheduleArmedUptime = nil
          logEvent("schedule_dispatched", record: record, fields: [
            "scheduledAt": scheduleTarget?.timeIntervalSince1970 ?? NSNull(),
            "pendingReconciliation": pending != nil,
          ])
        }
        try persist()
        let epoch = scheduledDue ? scheduleConfigurationEpoch : leadConfigurationEpoch
        let lead = state.leadMinutes
        let token = ResetCreditConsumptionCancellation()
        cancellation = token
        inFlight = true
        logEvent(pending == nil ? "operation_prepared" : "operation_reconcile", record: record,
          fields: ["triggerMode": scheduledDue ? "scheduled" : "expiry_lead"])
        notifyChange()
        queue.async { [weak self] in
          guard let self else { return }
          let result: Result<ResetCreditConsumeOutcome, Error>
          do {
            result = .success(try client.consumeResetCredit(
              auth: auth, identity: identity, creditID: record.creditID,
              idempotencyKey: record.idempotencyKey, leadMinutes: lead,
              reconciling: pending != nil, scheduledDue: scheduledDue,
              scheduleTarget: scheduleTarget, cancellation: token,
              authorizeSend: { transmit in
                try self.authorizeTransmission(
                  record: record, auth: auth, identity: identity, epoch: epoch,
                  scheduledDue: scheduledDue, scheduleTarget: scheduleTarget,
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
        if scheduledDue, let target = state.scheduledAt {
          state.scheduledAt = nil
          state.scheduledLastResult = "定时使用未能执行：\(error.localizedDescription)"
          scheduleTimer?.invalidate()
          scheduleTimer = nil
          scheduleAttempts = 0
          scheduleArmedAt = nil
          scheduleArmedUptime = nil
          logEvent("schedule_failed", fields: [
            "scheduledAt": target.timeIntervalSince1970,
          ], error: error)
        }
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
      leadConfigurationEpoch += 1
      scheduleConfigurationEpoch += 1
      scheduleTimer?.invalidate()
      scheduleTimer = nil
      logEvent("shutdown")
      return cancellation
    }
    token?.cancel()
  }

  /// Checks only the originating mode's configuration epoch before writing and transmitting.
  /// The shared lock/account binding still prevents overlap and preserves the exact retry card/key.
  private func authorizeTransmission(
    record: AutoUseRecord, auth: CodexAuth, identity: CodexAutoUseIdentity, epoch: Int,
    scheduledDue: Bool, scheduleTarget: Date?, transmit: () throws -> Void
  ) throws {
    try synchronized {
      try requireStorage()
      let currentEpoch = scheduledDue ? scheduleConfigurationEpoch : leadConfigurationEpoch
      guard (state.enabled || scheduledDue), currentEpoch == epoch,
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
        if scheduledDue {
          guard durable.expiresAt.timeIntervalSinceNow > 0 else {
            throw CodexQuotaError.transport("重置卡已过期，已取消定时使用")
          }
          guard let scheduleTarget,
            Date().timeIntervalSince(scheduleTarget) <= Self.scheduleExecutionTolerance
          else { throw CodexQuotaError.transport("已超过定时执行窗口，已取消提交") }
        } else {
          guard durable.expiresAt.timeIntervalSinceNow > 0,
            durable.expiresAt.timeIntervalSinceNow <= TimeInterval(state.leadMinutes * 60)
          else { throw CodexQuotaError.transport("重置卡已过期或尚未到使用时间") }
        }
      }
      durable.phase = .pending
      durable.attempts += 1
      durable.lastAttemptAt = Date()
      durable.retryAt = nil
      state.records[key] = durable
      try persist()
      logEvent("consume_submitting", record: durable, fields: [
        "triggerMode": scheduledDue ? "scheduled" : "expiry_lead",
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
          leadConfigurationEpoch += 1
          scheduleConfigurationEpoch += 1
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
    leadConfigurationEpoch += 1
    scheduleConfigurationEpoch += 1
    state.notice = "Codex 登录账号已切换，请为当前账号重新开启自动使用"
    if state.scheduledAt != nil {
      state.scheduledAt = nil
      state.scheduledLastResult = "Codex 登录账号已切换，定时使用已取消"
      scheduleTimer?.invalidate()
      scheduleTimer = nil
      scheduleArmedAt = nil
      scheduleArmedUptime = nil
    }
    try persist()
    logEvent("account_changed")
    notifyChange()
  }

  /// Installs or replaces the single one-shot timer, using the stored target unless retrying.
  /// Caller runs on the main thread because the timer is added to the main run loop.
  private func armScheduleTimer(retryDelay: TimeInterval? = nil) {
    scheduleTimer?.invalidate()
    scheduleTimer = nil
    guard storageError == nil, !isShuttingDown, let target = state.scheduledAt else { return }
    let fireDate: Date
    if let retryDelay {
      fireDate = Date().addingTimeInterval(retryDelay)
    } else if Date() >= target {
      fireDate = Date().addingTimeInterval(0.05)
    } else {
      fireDate = target
    }
    if retryDelay == nil {
      scheduleArmedAt = Date()
      scheduleArmedUptime = ProcessInfo.processInfo.systemUptime
    }
    let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
      self?.scheduleTimerFired()
    }
    timer.tolerance = 0
    RunLoop.main.add(timer, forMode: .common)
    scheduleTimer = timer
  }

  /// Starts one due-time refresh only inside the small latency window; later wakes are recorded as misses.
  /// The monotonic uptime gap detects sleep or a forward clock jump, which is never backfilled.
  /// The refresh itself is delegated to the store so all App Server work stays on its serial queue.
  private func scheduleTimerFired() {
    var callback: (() -> Void)?
    synchronized {
      scheduleTimer = nil
      guard let target = state.scheduledAt, storageError == nil, !isShuttingDown else { return }
      if let armedAt = scheduleArmedAt, let armedUptime = scheduleArmedUptime {
        let skipped = Date().timeIntervalSince(armedAt)
          - (ProcessInfo.processInfo.systemUptime - armedUptime)
        if skipped > 5 {
          markScheduleMissed(target: target, reason: "system_sleep")
          return
        }
      }
      let overdue = Date().timeIntervalSince(target)
      guard overdue <= Self.scheduleExecutionTolerance else {
        markScheduleMissed(target: target, reason: "timer_late")
        return
      }
      scheduleAttempts += 1
      logEvent("schedule_due", fields: [
        "scheduledAt": target.timeIntervalSince1970,
        "overdueSeconds": overdue,
        "attempt": scheduleAttempts,
      ])
      notifyChange()
      callback = onScheduleDue
    }
    callback?()
  }

  /// Clears an unfired target after the execution window, recording why it was skipped.
  /// Caller holds the state lock; a failed ledger write still leaves inspectable status text.
  private func markScheduleMissed(target: Date, reason: String, error: Error? = nil) {
    state.scheduledAt = nil
    state.scheduledLastResult = "已错过 \(DisplayFormatter.exact(target)) 的定时使用（未补执行）。"
    scheduleTimer?.invalidate()
    scheduleTimer = nil
    scheduleAttempts = 0
    scheduleArmedAt = nil
    scheduleArmedUptime = nil
    do { try persist() } catch {}
    logEvent("schedule_missed", fields: [
      "scheduledAt": target.timeIntervalSince1970,
      "reason": reason,
    ], error: error)
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
    payload["leadConfigurationEpoch"] = leadConfigurationEpoch
    payload["scheduleConfigurationEpoch"] = scheduleConfigurationEpoch
    payload["inFlight"] = inFlight
    payload["notice"] = state.notice
    payload["scheduledAt"] = state.scheduledAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
    payload["scheduleAttempts"] = scheduleAttempts
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
  /// Version 1 predates the fixed-time trigger; version 2 adds its two optional fields.
  var version = 2
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
  /// Armed one-shot wall-clock target; nil means no fixed-time use is scheduled.
  var scheduledAt: Date?
  /// Latest fixed-time result, miss or cancellation shown in the settings section.
  var scheduledLastResult: String?

  /// Memberwise construction remains available for new installations.
  init() {}

  /// Decodes version 1 files without the fixed-time fields so upgrades do not discard history.
  private enum CodingKeys: String, CodingKey {
    case version, enabled, leadMinutes, accountKey, authPath, records, notice, lastCompletion
    case scheduledAt, scheduledLastResult
  }

  /// Reads every optional field defensively; unknown or older payloads keep their defaults.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    leadMinutes = try container.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 10
    accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
    authPath = try container.decodeIfPresent(String.self, forKey: .authPath)
    records =
      try container.decodeIfPresent([String: AutoUseRecord].self, forKey: .records) ?? [:]
    notice =
      try container.decodeIfPresent(String.self, forKey: .notice)
      ?? "可按分钟设置到期前的自动使用时间"
    lastCompletion = try container.decodeIfPresent(String.self, forKey: .lastCompletion)
    scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
    scheduledLastResult = try container.decodeIfPresent(String.self, forKey: .scheduledLastResult)
  }
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
