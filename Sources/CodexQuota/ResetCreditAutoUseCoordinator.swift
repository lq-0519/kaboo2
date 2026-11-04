import Darwin
import Foundation

/// Evaluates always-enabled per-card times and optional expiry lead only after successful queries.
/// One lock protects the durable account/card ledger; RPC work uses the store's existing serial queue.
final class ResetCreditAutoUseCoordinator {
  /// Largest accepted whole-minute lead, allowing up to one year without arithmetic overflow.
  static let maximumLeadMinutes = 525_600
  /// Every first-seen finite-expiry card defaults to use thirty minutes before its service expiry.
  private static let defaultLead: TimeInterval = 30 * 60
  /// Dedicated diagnostics retain five approximately 5 MiB generations for user-driven inspection.
  static let log = RPCFileLogger(
    filename: "reset-credit-auto-use.log", maximumBytes: 5_242_880, retainedGenerations: 4
  )

  /// Serializes ledger access and the final durable-write/transmission boundary.
  private let lock = NSLock()
  /// Atomic private ledger location containing times and history, never OAuth or ID tokens.
  private let stateURL: URL
  /// Persisted global lead setting, account-bound card times and exact consumption identities.
  private var state = AutoUseState()
  /// Lifetime exclusive lock prevents competing utility instances from consuming the same card.
  private var lockDescriptor: Int32 = -1
  /// Corruption or durable-write failure blocks all submissions instead of forgetting history.
  private var storageError: String?
  /// An incompatible CLI pauses both conditions until the application is restarted after updating.
  private var protocolError: String?
  /// Invalidates queued lead work without cancelling another card's saved-time condition.
  private var leadConfigurationEpoch = 0
  /// Only one new submission or original-key reconciliation may be active at a time.
  private var inFlight = false
  /// Shutdown rejects queued sends while accepted results may still be persisted.
  private var isShuttingDown = false
  /// Native cleanup for the single active bounded App Server child.
  private var cancellation: ResetCreditConsumptionCancellation?
  /// Last successful service rows retained for display during transient refresh failures.
  private var cachedCards: [ResetCredit] = []
  /// Verified account of the cached rows, kept independently of the opt-in global lead binding.
  private var cardsIdentity: CodexAutoUseIdentity?
  /// Failed or identity-mismatched queries disable edits without deleting the previous display.
  private var cardsAreVerified = false
  /// Main-thread settings feedback; callbacks are always dispatched outside the state lock.
  var onChange: (() -> Void)?
  /// Requests display-only card and quota refreshes after confirmed use, never another selection.
  var onConsumed: (() -> Void)?

  /// Optional global earliest-expiry mode retains its existing default-off preference.
  var isEnabled: Bool { synchronized { state.enabled } }
  /// Whole-minute global lead, independent of each card's always-enabled absolute time.
  var leadMinutes: Int { synchronized { state.leadMinutes } }
  /// Storage, CLI or lifetime-lock failures prevent editing or executing automatic use.
  var isAvailable: Bool {
    synchronized { storageError == nil && protocolError == nil && !isShuttingDown }
  }
  /// Earliest-expiry-first settings rows; locally terminal cards disappear even in a stale snapshot.
  var cardRows: [ResetCreditUseRow] { synchronized { makeCardRows(now: Date()) } }
  /// Current feedback and the last confirmed use survive ordinary refreshes and app restarts.
  var statusText: String {
    synchronized {
      if let storageError { return storageError }
      if let protocolError { return protocolError }
      return state.notice + (state.lastCompletion.map { "\n\($0)" } ?? "")
    }
  }

  /// Loads the exclusive ledger and migrates only a legacy time tied to an explicit known card.
  /// Legacy global times cannot identify a card and are discarded; all operation history is retained.
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
        let loaded = try JSONDecoder().decode(AutoUseState.self, from: Data(contentsOf: stateURL))
        guard (1...4).contains(loaded.version),
          (1...Self.maximumLeadMinutes).contains(loaded.leadMinutes),
          !loaded.enabled || (loaded.accountKey?.isEmpty == false && loaded.authPath?.isEmpty == false),
          loaded.cardUseTimes.allSatisfy({ key, time in
            key == Self.recordKey(accountKey: time.accountKey, creditID: time.creditID)
              && !time.accountKey.isEmpty && !time.creditID.isEmpty && !time.authPath.isEmpty
              && time.expiresAt.timeIntervalSince1970.isFinite
              && time.useAt.timeIntervalSince1970.isFinite
          }),
          loaded.records.allSatisfy({ key, record in
            key == Self.recordKey(accountKey: record.accountKey, creditID: record.creditID)
              && !record.accountKey.isEmpty && !record.creditID.isEmpty
              && !record.idempotencyKey.isEmpty && record.attempts >= 0
              && record.expiresAt.timeIntervalSince1970.isFinite
          }),
          Dictionary(grouping: loaded.records.values.filter { $0.phase == .pending },
            by: { $0.accountKey }).values.allSatisfy({ $0.count <= 1 })
        else { throw CodexQuotaError.transport("自动使用记录版本或内容不兼容") }
        state = loaded
        state.version = 4
        if loaded.version < 4 {
          state.notice = "已升级为逐卡自动使用，等待重置卡刷新"
          try persist()
        }
      }
      logEvent("ledger_loaded")
    } catch {
      storageError = "自动使用暂不可用：\(error.localizedDescription)"
      logEvent("ledger_load_failed", error: error)
    }
  }

  /// Releases only the lifetime file lock; durable card settings and histories remain on disk.
  deinit {
    if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
  }

  /// Updates the display and initializes new cards even for a display-only settings-page query.
  /// A verified query binds defaults to its current account; unrelated accounts retain their history.
  /// Only changed defaults/metadata are persisted, avoiding a ledger write on every refresh.
  func updateCards(snapshot: ResetCreditsSnapshot, identity: CodexAutoUseIdentity?) {
    synchronized {
      guard let identity else {
        cardsAreVerified = false
        notifyChange()
        return
      }
      cachedCards = snapshot.items
      cardsIdentity = identity
      cardsAreVerified = true
      guard storageError == nil, !isShuttingDown else { notifyChange(); return }
      do {
        if state.enabled,
          state.accountKey != identity.key || state.authPath != identity.authPath
        {
          try pauseLeadForAccountChange()
        }
        var changed = false
        for card in snapshot.items {
          guard card.status == "available", let expiry = card.expiresAt,
            expiry.timeIntervalSince1970.isFinite, expiry > Date()
          else { continue }
          let key = Self.recordKey(accountKey: identity.key, creditID: card.id)
          let phase = state.records[key]?.phase
          guard phase != .used && phase != .unavailable else { continue }
          if var time = state.cardUseTimes[key] {
            if time.title != card.title || time.expiresAt != expiry || time.authPath != identity.authPath {
              if !time.isCustom { time.useAt = expiry.addingTimeInterval(-Self.defaultLead) }
              time.title = card.title
              time.expiresAt = expiry
              time.authPath = identity.authPath
              state.cardUseTimes[key] = time
              changed = true
            }
          } else {
            state.cardUseTimes[key] = ResetCreditUseTime(
              creditID: card.id, title: card.title, expiresAt: expiry,
              accountKey: identity.key, authPath: identity.authPath,
              useAt: expiry.addingTimeInterval(-Self.defaultLead)
            )
            changed = true
            logEvent("card_time_initialized", fields: [
              "cardAccountKey": identity.key, "creditID": card.id,
              "useAt": expiry.addingTimeInterval(-Self.defaultLead).timeIntervalSince1970,
            ])
          }
        }
        if changed { try persist() }
      } catch {
        logEvent("card_times_update_failed", error: error)
      }
      notifyChange()
    }
  }

  /// Saves one row's time immediately after editing; it does not query or consume the card.
  /// Past times are allowed and become due on the next successful poll, provided the card is unexpired.
  func setCardUseTime(accountKey: String, creditID: String, at date: Date, auth: CodexAuth) throws {
    try synchronized {
      try requireStorage()
      let identity = try CodexAuthStore().autoUseIdentity(for: auth)
      let key = Self.recordKey(accountKey: accountKey, creditID: creditID)
      guard cardsAreVerified, cardsIdentity?.key == identity.key,
        cardsIdentity?.authPath == identity.authPath, identity.key == accountKey,
        let row = makeCardRows(now: Date()).first(where: { $0.creditID == creditID }),
        row.canEdit, let expiry = row.expiresAt, var time = state.cardUseTimes[key]
      else { throw CodexQuotaError.transport("该卡暂不可编辑，请等待当前账号的重置卡刷新") }
      guard date.timeIntervalSince1970.isFinite, date < expiry else {
        throw CodexQuotaError.transport("自动使用时间必须早于这张卡的到期时间")
      }
      guard time.useAt != date || !time.isCustom else { return }
      time.useAt = date
      time.isCustom = true
      state.cardUseTimes[key] = time
      state.notice = "已保存 \(time.title) 的自动使用时间，等待后续刷新"
      try persist()
      logEvent("card_time_changed", fields: [
        "cardAccountKey": accountKey, "creditID": creditID, "useAt": date.timeIntervalSince1970,
      ])
      notifyChange()
    }
  }

  /// Binds the optional earliest-expiry switch to the current login without changing card times.
  /// Disabling rejects only unsent lead work; pending requests keep their exact reconciliation key.
  func setEnabled(_ enabled: Bool, auth: CodexAuth?) throws {
    try synchronized {
      try requireStorage()
      if enabled {
        guard let auth else { throw CodexQuotaError.notSignedIn }
        let identity = try CodexAuthStore().autoUseIdentity(for: auth)
        state.accountKey = identity.key
        state.authPath = identity.authPath
      }
      leadConfigurationEpoch += 1
      state.enabled = enabled
      state.notice = enabled
        ? "到期前自动使用已开启；每张卡的指定时间也继续生效"
        : "到期前自动使用已关闭；每张卡仍按指定时间自动使用"
      try persist()
      logEvent("settings_enabled_changed")
      notifyChange()
    }
  }

  /// Saves the bounded integer-minute lead for future successful polls without changing any card time.
  func setLeadMinutes(_ minutes: Int) throws {
    try synchronized {
      try requireStorage()
      let bounded = min(Self.maximumLeadMinutes, max(1, minutes))
      guard bounded != state.leadMinutes else { return }
      leadConfigurationEpoch += 1
      state.leadMinutes = bounded
      try persist()
      logEvent("settings_lead_changed")
      notifyChange()
    }
  }

  /// Keeps stale display rows but blocks editing/selection until a successful identity-verified query.
  /// Failure never starts a retry timer or interprets cached cards as fresh execution evidence.
  func reportRefreshFailure(_ error: Error) {
    synchronized {
      guard storageError == nil, !isShuttingDown else { return }
      cardsAreVerified = false
      state.notice = "重置卡刷新失败，等待后续成功刷新：\(error.localizedDescription)"
      logEvent("credit_refresh_failed", error: error)
      notifyChange()
    }
  }

  /// Evaluates both conditions on a successful existing poll and dispatches at most one exact card.
  /// Original-key reconciliation precedes every new card, even when global lead mode is disabled.
  func observe(
    snapshot: ResetCreditsSnapshot, auth: CodexAuth,
    client: CodexAppServerClient, queue: DispatchQueue
  ) {
    synchronized {
      guard storageError == nil, protocolError == nil, !isShuttingDown, !inFlight else {
        logEvent("refresh_skipped", fields: ["reason": "unavailable_or_in_flight"])
        return
      }
      do {
        let identity = try CodexAuthStore().autoUseIdentity(for: auth)
        guard cardsAreVerified, cardsIdentity?.key == identity.key,
          cardsIdentity?.authPath == identity.authPath
        else { throw CodexQuotaError.transport("无法核对当前重置卡列表的登录身份") }
        let now = Date()
        let pending = state.records.values.first {
          $0.accountKey == identity.key && $0.phase == .pending
        }
        let terminalIDs = Set(state.records.values.filter {
          $0.accountKey == identity.key && ($0.phase == .used || $0.phase == .unavailable)
        }.map { $0.creditID })
        let eligible = snapshot.items.filter {
          $0.status == "available" && !terminalIDs.contains($0.id)
            && $0.expiresAt.map { $0.timeIntervalSince1970.isFinite && $0 > now } == true
        }.sorted {
          ($0.expiresAt ?? .distantFuture, $0.id) < ($1.expiresAt ?? .distantFuture, $1.id)
        }
        var selected = pending
        var trigger: ResetCreditUseTrigger = .reconciliation
        var decisions: [[String: Any]] = []
        if pending == nil, snapshot.availableCount > 0 {
          for card in eligible {
            let key = Self.recordKey(accountKey: identity.key, creditID: card.id)
            guard let expiry = card.expiresAt else { continue }
            let time = state.cardUseTimes[key]
            let dueTime = time.map {
              $0.authPath == identity.authPath && $0.useAt <= now && $0.useAt < expiry
            } ?? false
            let dueLead = state.enabled && state.accountKey == identity.key
              && state.authPath == identity.authPath && eligible.first?.id == card.id
              && expiry.timeIntervalSince(now) <= TimeInterval(state.leadMinutes * 60)
            let reason: String
            if selected != nil {
              reason = "one_card_per_refresh"
            } else if dueTime || dueLead {
              var record = state.records[key] ?? AutoUseRecord(
                accountKey: identity.key, creditID: card.id, title: card.title, expiresAt: expiry
              )
              // nothingToReset definitively ended the old attempt; prepared/pending retries keep UUIDs.
              if record.phase == .waiting {
                record.idempotencyKey = UUID().uuidString
                record.phase = .prepared
                record.attempts = 0
                record.retryAt = nil
              }
              record.title = card.title
              record.expiresAt = expiry
              selected = record
              trigger = dueTime ? .cardTime(time!.useAt) : .expiryLead(state.leadMinutes)
              reason = "selected"
            } else {
              reason = "not_due"
            }
            decisions.append([
              "creditID": card.id, "expiresAt": expiry.timeIntervalSince1970,
              "useAt": time.map { $0.useAt.timeIntervalSince1970 as Any } ?? NSNull(),
              "dueCardTime": dueTime, "dueExpiryLead": dueLead, "reason": reason,
            ])
          }
        }
        logEvent("refresh_checked", fields: [
          "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970,
          "availableCount": snapshot.availableCount, "cardAccountKey": identity.key,
          "decisions": decisions, "triggerMode": trigger.logName,
        ])
        guard let record = selected else {
          state.notice = "等待每张卡的自动使用时间"
          notifyChange()
          return
        }
        if let retryAt = record.retryAt, retryAt > now {
          state.notice = "等待后续刷新重试；待核对请求继续使用原卡和原幂等键"
          logEvent("retry_deferred", record: record)
          notifyChange()
          return
        }
        state.records[Self.recordKey(accountKey: identity.key, creditID: record.creditID)] = record
        state.notice = pending == nil ? "正在核对重置卡：\(record.title)" : "正在核对上次使用结果"
        try persist()
        let epoch = leadConfigurationEpoch
        let capturedTrigger = trigger
        let token = ResetCreditConsumptionCancellation()
        cancellation = token
        inFlight = true
        logEvent(pending == nil ? "operation_prepared" : "operation_reconcile", record: record,
          fields: ["triggerMode": trigger.logName])
        notifyChange()
        queue.async { [weak self] in
          guard let self else { return }
          let result: Result<ResetCreditConsumeOutcome, Error>
          do {
            result = .success(try client.consumeResetCredit(
              auth: auth, identity: identity, creditID: record.creditID,
              idempotencyKey: record.idempotencyKey, trigger: capturedTrigger,
              terminalCreditIDs: terminalIDs, cancellation: token,
              authorizeSend: { transmit in
                try self.authorizeTransmission(
                  record: record, auth: auth, identity: identity, trigger: capturedTrigger,
                  leadEpoch: epoch, transmit: transmit
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

  /// Rejects queued work and cancels the active transport while retaining all ambiguous identities.
  func shutdown() {
    let token: ResetCreditConsumptionCancellation? = synchronized {
      isShuttingDown = true
      leadConfigurationEpoch += 1
      logEvent("shutdown")
      return cancellation
    }
    token?.cancel()
  }

  /// Rechecks current login and only the originating condition under the durable transmission lock.
  /// A pending reconciliation bypasses time preferences but always retains the original exact card/key.
  private func authorizeTransmission(
    record: AutoUseRecord, auth: CodexAuth, identity: CodexAutoUseIdentity,
    trigger: ResetCreditUseTrigger, leadEpoch: Int, transmit: () throws -> Void
  ) throws {
    try synchronized {
      try requireStorage()
      let current = try CodexAuthStore().autoUseIdentity(for: auth)
      guard current.key == identity.key, current.authPath == identity.authPath,
        cardsAreVerified, cardsIdentity?.key == identity.key,
        cardsIdentity?.authPath == identity.authPath
      else { throw CodexQuotaError.transport("Codex 登录已改变，取消尚未提交的自动使用") }
      let key = Self.recordKey(accountKey: record.accountKey, creditID: record.creditID)
      guard var durable = state.records[key],
        durable.idempotencyKey == record.idempotencyKey,
        durable.phase == .prepared || durable.phase == .pending
      else { throw CodexQuotaError.transport("自动使用记录不一致，已停止提交") }
      let now = Date()
      switch trigger {
      case .reconciliation:
        guard durable.phase == .pending else {
          throw CodexQuotaError.transport("原提交不再需要核对")
        }
      case .cardTime(let useAt):
        guard let time = state.cardUseTimes[key], time.authPath == identity.authPath,
          time.useAt == useAt, useAt <= now, useAt < durable.expiresAt, durable.expiresAt > now
        else { throw CodexQuotaError.transport("卡片时间已改变或已过期，取消尚未提交的使用") }
      case .expiryLead(let minutes):
        guard state.enabled, leadConfigurationEpoch == leadEpoch,
          state.accountKey == identity.key, state.authPath == identity.authPath,
          state.leadMinutes == minutes, durable.expiresAt > now,
          durable.expiresAt.timeIntervalSince(now) <= TimeInterval(minutes * 60)
        else { throw CodexQuotaError.transport("到期前设置已改变或卡已过期，取消尚未提交的使用") }
      }
      durable.phase = .pending
      durable.attempts += 1
      durable.lastAttemptAt = now
      durable.retryAt = nil
      state.records[key] = durable
      try persist()
      logEvent("consume_submitting", record: durable, fields: [
        "triggerMode": trigger.logName,
        "params": ["creditId": durable.creditID, "idempotencyKey": durable.idempotencyKey],
      ])
      try transmit()
    }
  }

  /// Persists accepted results under the original account before asking for display-only refreshes.
  /// Unknown/transport failures retain pending identity; only nothingToReset permits a later new UUID.
  private func finish(result: Result<ResetCreditConsumeOutcome, Error>, record: AutoUseRecord) {
    synchronized {
      inFlight = false
      cancellation = nil
      let key = Self.recordKey(accountKey: record.accountKey, creditID: record.creditID)
      guard var durable = state.records[key], durable.idempotencyKey == record.idempotencyKey else {
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
        let delay = min(900.0, 60.0 * pow(2.0, Double(min(4, max(0, durable.attempts - 1)))))
        durable.retryAt = Date().addingTimeInterval(delay)
        state.notice = durable.phase == .pending
          ? "使用结果待核对，将沿用原卡和原幂等键；\(error.localizedDescription)"
          : "尚未提交使用请求，等待后续刷新；\(error.localizedDescription)"
        if let failure = error as? CodexQuotaError,
          case .rpc(let code, _) = failure, code == -32601 || code == -32602
        {
          protocolError = "当前 Codex 不支持自动使用接口，请更新 CLI 后重新启动；RPC \(code)"
        }
        logEvent("consume_failed", record: durable, error: error)
      }
      state.records[key] = durable
      do { try persist() } catch {
        // On-disk pending retains the original UUID even if accepted-result persistence fails.
        logEvent("result_persist_failed", record: durable, error: error)
        consumed = false
      }
      notifyChange()
      if consumed, !isShuttingDown {
        DispatchQueue.main.async { [weak self] in self?.onConsumed?() }
      }
    }
  }

  /// Builds a compact sorted list without RPCs; pending cards remain visible even after disappearance.
  /// Terminal history wins over stale service availability and disables editing during reconciliation.
  private func makeCardRows(now: Date) -> [ResetCreditUseRow] {
    guard let identity = cardsIdentity else { return [] }
    let canEdit = cardsAreVerified && storageError == nil && protocolError == nil
      && !isShuttingDown && !inFlight
      && !state.records.values.contains { $0.accountKey == identity.key && $0.phase == .pending }
    var rows: [ResetCreditUseRow] = []
    var seen = Set<String>()
    for card in cachedCards {
      let key = Self.recordKey(accountKey: identity.key, creditID: card.id)
      let phase = state.records[key]?.phase
      guard phase != .used && phase != .unavailable else { continue }
      let expiry = card.expiresAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
      guard phase == .pending || (card.status == "available" && (expiry.map { $0 > now } ?? true))
      else { continue }
      let time = state.cardUseTimes[key]
      let status = phase == .pending ? "使用结果待核对"
        : (!cardsAreVerified ? "等待刷新核对" : (expiry == nil ? "缺少有效期，无法自动使用" : ""))
      rows.append(ResetCreditUseRow(
        accountKey: identity.key, creditID: card.id, title: card.title, expiresAt: expiry,
        useAt: expiry == nil ? nil : time?.useAt,
        canEdit: canEdit && expiry != nil && time != nil, statusText: status
      ))
      seen.insert(card.id)
    }
    for record in state.records.values where record.accountKey == identity.key
      && record.phase == .pending && !seen.contains(record.creditID)
    {
      let time = state.cardUseTimes[Self.recordKey(accountKey: identity.key, creditID: record.creditID)]
      rows.append(ResetCreditUseRow(
        accountKey: identity.key, creditID: record.creditID, title: record.title,
        expiresAt: record.expiresAt, useAt: time?.useAt, canEdit: false,
        statusText: "使用结果待核对"
      ))
    }
    return rows.sorted {
      ($0.expiresAt ?? .distantFuture, $0.creditID) < ($1.expiresAt ?? .distantFuture, $1.creditID)
    }
  }

  /// Pauses only the old global lead opt-in; per-card times remain scoped to their own verified login.
  private func pauseLeadForAccountChange() throws {
    state.enabled = false
    leadConfigurationEpoch += 1
    state.notice = "登录账号已切换；新账号的卡按各自时间使用，到期前功能需重新开启"
    try persist()
    logEvent("lead_account_changed")
  }

  /// Rejects settings and new submissions after any storage/CLI failure or shutdown.
  /// Result persistence bypasses this guard so accepted outcomes can still reach durable storage.
  private func requireStorage() throws {
    if let storageError { throw CodexQuotaError.transport(storageError) }
    if let protocolError { throw CodexQuotaError.transport(protocolError) }
    if isShuttingDown { throw CodexQuotaError.transport("软件正在退出") }
  }

  /// Writes a private temporary file, fsyncs it, atomically renames it and fsyncs the directory.
  /// Pending intent must reach durable storage before any consuming bytes are transmitted.
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

  /// Serializes ledger access; callers deliberately avoid nesting synchronized operations.
  private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// Stable user/workspace/card key shared by saved times and consumption history.
  private static func recordKey(accountKey: String, creditID: String) -> String {
    "\(accountKey):\(creditID)"
  }

  /// Enqueues main-thread UI feedback after the current ledger operation releases its lock.
  private func notifyChange() {
    DispatchQueue.main.async { [weak self] in self?.onChange?() }
  }

  /// Writes complete decision/configuration JSON without login tokens; callers hold the state lock.
  private func logEvent(
    _ event: String, record: AutoUseRecord? = nil, fields: [String: Any] = [:], error: Error? = nil
  ) {
    var payload = fields
    payload["event"] = event
    payload["enabled"] = state.enabled
    payload["leadMinutes"] = state.leadMinutes
    payload["accountKey"] = state.accountKey.map { $0 as Any } ?? NSNull()
    payload["authPath"] = state.authPath.map { $0 as Any } ?? NSNull()
    payload["recordCount"] = state.records.count
    payload["cardTimeCount"] = state.cardUseTimes.count
    payload["leadConfigurationEpoch"] = leadConfigurationEpoch
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

/// Versioned atomic ledger retaining per-card times and exact original operations across upgrades.
private struct AutoUseState: Codable {
  /// Version four replaces the legacy shared card selector/global time with per-card entries.
  var version = 4
  /// Optional global expiry-lead preference; per-card absolute times do not depend on this switch.
  var enabled = false
  /// Positive whole-minute lead for the current earliest-expiring card, initially ten minutes.
  var leadMinutes = 10
  /// Stable account digest to which the optional global lead switch is bound.
  var accountKey: String?
  /// Canonical authentication path for the global lead opt-in.
  var authPath: String?
  /// Exact original operation history keyed by stable account/card identity.
  var records: [String: AutoUseRecord] = [:]
  /// Always-enabled absolute times keyed by the same stable account/card identity.
  var cardUseTimes: [String: ResetCreditUseTime] = [:]
  /// Latest user-facing feedback, without historical conversation records.
  var notice = "每张卡默认在到期前 30 分钟自动使用"
  /// Latest confirmed card result, retained independently of waiting feedback.
  var lastCompletion: String?

  /// Default initializer starts with no known cards; successful queries populate their defaults.
  init() {}

  /// Legacy keys are decoded only for migration and are never written into version four.
  private enum CodingKeys: String, CodingKey {
    case version, enabled, leadMinutes, accountKey, authPath, records, cardUseTimes, notice, lastCompletion
    case scheduledAt, selectedCard
  }

  /// Preserves all prior operations and migrates a legacy exact time only for a known bound card.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    leadMinutes = try container.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 10
    accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
    authPath = try container.decodeIfPresent(String.self, forKey: .authPath)
    records = try container.decodeIfPresent([String: AutoUseRecord].self, forKey: .records) ?? [:]
    cardUseTimes = try container.decodeIfPresent([String: ResetCreditUseTime].self, forKey: .cardUseTimes) ?? [:]
    notice = try container.decodeIfPresent(String.self, forKey: .notice) ?? notice
    lastCompletion = try container.decodeIfPresent(String.self, forKey: .lastCompletion)
    if version < 4,
      let target = try container.decodeIfPresent(Date.self, forKey: .scheduledAt),
      let choice = try container.decodeIfPresent(LegacyCreditSelection.self, forKey: .selectedCard),
      !choice.requiresReselection, choice.accountKey == accountKey, choice.authPath == authPath,
      !choice.accountKey.isEmpty, !choice.creditID.isEmpty, !choice.authPath.isEmpty,
      target.timeIntervalSince1970.isFinite, choice.expiresAt.timeIntervalSince1970.isFinite,
      target < choice.expiresAt
    {
      cardUseTimes["\(choice.accountKey):\(choice.creditID)"] = ResetCreditUseTime(
        creditID: choice.creditID, title: choice.title, expiresAt: choice.expiresAt,
        accountKey: choice.accountKey, authPath: choice.authPath, useAt: target, isCustom: true
      )
    }
  }

  /// Writes only the current schema, preserving preferences/history without obsolete UI settings.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(leadMinutes, forKey: .leadMinutes)
    try container.encodeIfPresent(accountKey, forKey: .accountKey)
    try container.encodeIfPresent(authPath, forKey: .authPath)
    try container.encode(records, forKey: .records)
    try container.encode(cardUseTimes, forKey: .cardUseTimes)
    try container.encode(notice, forKey: .notice)
    try container.encodeIfPresent(lastCompletion, forKey: .lastCompletion)
  }
}

/// Decode-only version-three choice used to identify which legacy card owned a saved exact time.
private struct LegacyCreditSelection: Decodable {
  /// Original exact backend ID; an unbound legacy global target is never assigned to another card.
  let creditID: String
  /// Saved title retained until the next successful query supplies current metadata.
  let title: String
  /// Previously verified expiry used to validate the migrated use time.
  let expiresAt: Date
  /// Original stable user/workspace digest.
  let accountKey: String
  /// Original canonical login-file path.
  let authPath: String
  /// Paused legacy selections cannot grant a new account permission to consume their card.
  let requiresReselection: Bool
}

/// Distinguishes definite non-submission from uncertain completion and terminal card outcomes.
private enum AutoUsePhase: String, Codable {
  /// Saved intent whose consuming bytes have not crossed the durable transmission boundary.
  case prepared
  /// Request may have reached the backend; only its original UUID may be retried.
  case pending
  /// Explicit nothingToReset ended this attempt without using the card.
  case waiting
  /// Confirmed reset/alreadyRedeemed permanently suppresses this account/card ID.
  case used
  /// Explicit noCredit permanently suppresses further submissions for this account/card ID.
  case unavailable
}

/// Durable card operation preserving every field from previous versions for exact reconciliation.
private struct AutoUseRecord: Codable {
  /// Original stable account digest, never reassigned on a login change.
  let accountKey: String
  /// Exact backend ID supplied on every initial or reconciliation submission.
  let creditID: String
  /// Last verified service title.
  var title: String
  /// Last verified finite expiry; new operations never select a missing-expiry card.
  var expiresAt: Date
  /// Original logical operation UUID retained after ambiguous errors, shutdown and restart.
  var idempotencyKey = UUID().uuidString
  /// Pending is durably written before consuming bytes are sent.
  var phase: AutoUsePhase = .prepared
  /// Count of actual transmission attempts for bounded refresh-driven backoff.
  var attempts = 0
  /// Last transmission instant for diagnostic correlation.
  var lastAttemptAt: Date?
  /// Earliest retry instant checked only by successful existing credit queries.
  var retryAt: Date?
  /// Most recent recognized backend outcome.
  var lastOutcome: String?
  /// Latest transport/protocol failure without credentials.
  var lastError: String?
}
