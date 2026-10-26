import Darwin
import Foundation

/// Local bounded logger that preserves complete JSON-RPC lines without unified-log truncation.
private let codexRPCLog = RPCFileLogger.shared

/// Performs bounded reset-credit queries and explicitly authorized, idempotent card consumption.
final class CodexAppServerClient {
  /// File manager used to discover executable candidates without invoking a shell.
  private let fileManager: FileManager

  /// Creates a client with an injectable file manager for executable discovery.
  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  /// Starts App Server, reads the account-bound credit snapshot, and always stops the child.
  func readResetCredits(auth: CodexAuth) throws -> ResetCreditsSnapshot {
    try withSession(auth: auth) { session in
      _ = try readAccount(session: session)
      return try parseCredits(readRateLimits(session: session, auth: auth))
    }
  }

  /// Revalidates login and the latest card list in the same child before using one specific card.
  /// Reconciliation always reuses the original card/key even if the card vanished or expired.
  /// The authorization callback durably records intent and transmits under the coordinator lock,
  /// so disabling or editing settings cannot race a not-yet-submitted consume request.
  func consumeResetCredit(
    auth: CodexAuth, identity: CodexAutoUseIdentity, creditID: String,
    idempotencyKey: String, leadMinutes: Int, reconciling: Bool,
    cancellation: ResetCreditConsumptionCancellation,
    authorizeSend: @escaping (_ transmit: () throws -> Void) throws -> Void
  ) throws -> ResetCreditConsumeOutcome {
    guard !cancellation.isCancelled else { throw CodexQuotaError.transport("自动使用已停止") }
    return try withSession(
      auth: auth, diagnostics: ResetCreditAutoUseCoordinator.log, cancellation: cancellation
    ) { session in
      let currentIdentity = try CodexAuthStore().autoUseIdentity(for: auth)
      guard currentIdentity.key == identity.key, currentIdentity.authPath == identity.authPath else {
        throw CodexQuotaError.transport("Codex 账号已切换")
      }
      let account = try readAccount(session: session)
      guard let email = account["email"] as? String,
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == identity.email
      else {
        throw CodexQuotaError.transport("Codex App Server 登录身份不一致")
      }
      let snapshot = try parseCredits(readRateLimits(session: session, auth: auth))
      let expiresAt = snapshot.items.first(where: { $0.id == creditID })?.expiresAt
      let result = try session.call(
        method: "account/rateLimitResetCredit/consume",
        params: ["creditId": creditID, "idempotencyKey": idempotencyKey],
        authorizeSend: { transmit in
          if !reconciling {
            guard snapshot.availableCount > 0, let expiresAt,
              expiresAt.timeIntervalSinceNow > 0,
              expiresAt.timeIntervalSinceNow <= TimeInterval(leadMinutes * 60)
            else {
              throw CodexQuotaError.transport("该重置卡已不可用、已过期或尚未到自动使用时间")
            }
          }
          try authorizeSend(transmit)
        }
      )
      guard let raw = result["outcome"] as? String,
        let outcome = ResetCreditConsumeOutcome(rawValue: raw)
      else {
        throw CodexQuotaError.invalidResponse
      }
      return outcome
    }
  }

  /// Creates and initializes one bounded child; all callers share shutdown and diagnostic rules.
  /// Automatic operations mirror every RPC and child diagnostic to their dedicated private log.
  private func withSession<T>(
    auth: CodexAuth, diagnostics: RPCFileLogger? = nil,
    cancellation: ResetCreditConsumptionCancellation? = nil,
    body: (AppServerSession) throws -> T
  ) throws -> T {
    let executable = try locateExecutable()
    let session = try AppServerSession(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments(for: auth),
      environment: sanitizedEnvironment(authPath: auth.authPath),
      diagnostics: diagnostics
    )
    cancellation?.register { session.close(reason: "auto_use_shutdown") }
    let timeout = DispatchWorkItem {
      session.close(reason: "timeout")
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: timeout)
    defer {
      timeout.cancel()
      cancellation?.clear()
      session.close()
    }

    _ = try session.call(
      method: "initialize",
      params: [
        "clientInfo": [
          "name": "codex_quota",
          "version": "1.0.0",
        ]
      ]
    )
    try session.notify(method: "initialized", params: nil)
    return try body(session)
  }

  /// Rejects API-key sessions without refreshing credentials or performing interactive login.
  private func readAccount(session: AppServerSession) throws -> [String: Any] {
    let accountResult = try session.call(
      method: "account/read",
      params: ["refreshToken": false]
    )
    guard let account = accountResult["account"] as? [String: Any],
      account["type"] as? String == "chatgpt"
    else {
      throw CodexQuotaError.notSignedIn
    }

    return account
  }

  /// Checks the optional upstream workspace field against the child process's pinned workspace.
  private func readRateLimits(session: AppServerSession, auth: CodexAuth) throws -> [String: Any] {
    let result = try session.call(method: "account/rateLimits/read", params: nil)
    if let responseAccountID = result["accountId"] as? String,
      !responseAccountID.isEmpty,
      responseAccountID != auth.accountID
    {
      throw CodexQuotaError.transport("Codex 账户已切换")
    }
    return result
  }

  /// Builds the least-privilege App Server command line without placing credentials in argv.
  private func arguments(for auth: CodexAuth) -> [String] {
    [
      "app-server",
      "--listen",
      "stdio://",
      "-c",
      "cli_auth_credentials_store=\"file\"",
      "-c",
      "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
      "-c",
      "forced_chatgpt_workspace_id=\(tomlQuoted(auth.accountID))",
      "-c",
      "forced_login_method=\"chatgpt\"",
      "-c",
      "check_for_update_on_startup=false",
      "-c",
      "analytics.enabled=false",
      "-c",
      "model_provider=\"openai\"",
      "-c",
      "otel.exporter=\"none\"",
      "-c",
      "otel.trace_exporter=\"none\"",
    ]
  }

  /// Removes credential and telemetry overrides before assigning Codex its explicit home.
  private func sanitizedEnvironment(authPath: String) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys {
      let upper = key.uppercased()
      if upper.hasPrefix("CODEX_")
        || upper.hasPrefix("OPENAI_")
        || upper.hasPrefix("OTEL_")
        || upper.hasSuffix("_PROXY")
        || upper == "RUST_LOG"
      {
        environment.removeValue(forKey: key)
      }
    }
    environment["CODEX_HOME"] = (authPath as NSString).deletingLastPathComponent
    return environment
  }

  /// Escapes a workspace identifier as a quoted TOML string for a config override.
  private func tomlQuoted(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// Locates the CLI or bundled launcher from deterministic, executable-only paths.
  private func locateExecutable() throws -> String {
    let home = fileManager.homeDirectoryForCurrentUser.path
    var candidates = [
      "\(home)/.local/bin/codex",
      "\(home)/.npm-global/bin/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
      "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
      "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
    ]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates.insert(
        contentsOf: path.split(separator: ":").map { "\($0)/codex" },
        at: 0
      )
    }
    guard let executable = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
      throw CodexQuotaError.codexNotFound
    }
    return executable
  }

  /// Validates and sorts the reset-credit detail rows while preserving the authoritative count.
  private func parseCredits(_ result: [String: Any]) throws -> ResetCreditsSnapshot {
    guard let summary = result["rateLimitResetCredits"] as? [String: Any],
      let countNumber = summary["availableCount"] as? NSNumber
    else {
      throw CodexQuotaError.invalidResponse
    }
    let availableCount = countNumber.intValue
    guard (0...1_000).contains(availableCount) else {
      throw CodexQuotaError.invalidResponse
    }

    let rows = summary["credits"] as? [[String: Any]] ?? []
    guard rows.count <= 1_000 else {
      throw CodexQuotaError.invalidResponse
    }
    var seen = Set<String>()
    let items = rows.compactMap { row -> ResetCredit? in
      guard let id = row["id"] as? String,
        !id.isEmpty,
        seen.insert(id).inserted
      else {
        return nil
      }
      let status = row["status"] as? String ?? "unknown"
      let resetType = row["resetType"] as? String ?? "unknown"
      guard status == "available", resetType == "codexRateLimits" else {
        return nil
      }
      let rawTitle = (row["title"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let title = rawTitle?.isEmpty == false ? rawTitle! : "额度重置卡"
      let expiresAt = (row["expiresAt"] as? NSNumber)
        .map { Date(timeIntervalSince1970: $0.doubleValue) }
      return ResetCredit(id: id, title: title, status: status, expiresAt: expiresAt)
    }.sorted {
      switch ($0.expiresAt, $1.expiresAt) {
      case (let left?, let right?):
        return left < right
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      case (nil, nil):
        return $0.id < $1.id
      }
    }

    return ResetCreditsSnapshot(
      availableCount: availableCount,
      items: items,
      fetchedAt: Date()
    )
  }
}

/// Owns one newline-delimited JSON-RPC child process and its deterministic shutdown.
private final class AppServerSession {
  /// Correlation identity disambiguating repeated numeric RPC IDs from different CLI children.
  private let sessionID = UUID().uuidString

  /// Optional dedicated auto-use log receiving the same complete request and response records.
  private let diagnostics: RPCFileLogger?

  /// Child Codex process serving JSON-RPC over native pipes.
  private let process: Process

  /// Writable stdin endpoint used to send JSON-RPC messages.
  private let input: FileHandle

  /// Readable stdout endpoint used to receive newline-delimited JSON-RPC messages.
  private let output: FileHandle

  /// Private temporary stderr file that lets the child write diagnostics without filling a pipe.
  private let diagnosticsURL: URL

  /// Writable stderr endpoint kept open until the child has exited and all diagnostics are available.
  private let diagnosticsOutput: FileHandle

  /// Launch timestamp used to distinguish immediate startup failures from the query timeout.
  private let startedAt = Date()

  /// Records successful launch so failed launches never access unavailable process exit information.
  private var hasLaunched = false

  /// Lock serializing complete shutdown and diagnostic logging across timeout and normal cleanup.
  private let closeLock = NSLock()

  /// Buffered bytes retained when a pipe read contains more than one JSON line.
  private var readBuffer = Data()

  /// Monotonic request identifier scoped to this one child process.
  private var nextID = 0

  /// Indicates that pipe and process teardown has already started.
  private var isClosed = false

  /// Launches a shell-free App Server process in the system temporary directory.
  init(
    executableURL: URL, arguments: [String], environment: [String: String],
    diagnostics: RPCFileLogger? = nil
  ) throws {
    self.diagnostics = diagnostics
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    input = inputPipe.fileHandleForWriting
    output = outputPipe.fileHandleForReading
    diagnosticsURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-quota-app-server-\(UUID().uuidString).stderr")
    guard
      FileManager.default.createFile(
        atPath: diagnosticsURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw CodexQuotaError.transport("无法创建 Codex 错误日志")
    }
    do {
      diagnosticsOutput = try FileHandle(forWritingTo: diagnosticsURL)
    } catch {
      try? FileManager.default.removeItem(at: diagnosticsURL)
      throw CodexQuotaError.transport("无法打开 Codex 错误日志")
    }
    process.standardError = diagnosticsOutput
    do {
      try process.run()
      hasLaunched = true
    } catch {
      close(reason: "launch_failed", error: error)
      throw CodexQuotaError.transport("无法启动 Codex")
    }
  }

  /// Sends one request and returns its result object while faithfully logging JSON and errors.
  func call(
    method: String, params: Any?,
    authorizeSend: ((_ transmit: () throws -> Void) throws -> Void)? = nil
  ) throws -> [String: Any] {
    nextID += 1
    let requestID = nextID
    let request: [String: Any] = [
      "id": requestID,
      "method": method,
      "params": params ?? NSNull(),
    ]
    let encoded = try encode(request)
    let requestJSON = String(data: encoded, encoding: .utf8) ?? "{}"
    var responseJSON: String?
    var requestError: Error?
    let startedAt = Date()
    defer {
      codexRPCLog.write(kind: "request", payload: requestJSON)
      if let responseJSON {
        codexRPCLog.write(kind: "response", payload: responseJSON)
      }
      if let requestError {
        codexRPCLog.write(kind: "error", payload: requestError.localizedDescription)
      }
      logRPC(
        event: "rpc_finished", method: method, requestID: requestID,
        requestJSON: requestJSON, responseJSON: responseJSON, error: requestError,
        duration: Date().timeIntervalSince(startedAt)
      )
    }

    do {
      logRPC(
        event: "rpc_started", method: method, requestID: requestID, requestJSON: requestJSON
      )
      if let authorizeSend {
        try authorizeSend { try self.write(encoded) }
      } else {
        try write(encoded)
      }
      while true {
        let message = try readMessage()
        guard let id = (message.object["id"] as? NSNumber)?.intValue else {
          continue
        }
        if message.object["method"] != nil {
          try refuseServerRequest(id: id)
          continue
        }
        guard id == requestID else {
          continue
        }
        responseJSON = message.rawJSON
        if let rpcError = message.object["error"] as? [String: Any] {
          let code = (rpcError["code"] as? NSNumber)?.intValue ?? 0
          let text = rpcError["message"] as? String ?? "RPC \(code)"
          throw CodexQuotaError.rpc(code: code, message: text)
        }
        guard let result = message.object["result"] as? [String: Any] else {
          throw CodexQuotaError.invalidResponse
        }
        return result
      }
    } catch {
      requestError = error
      throw error
    }
  }

  /// Sends a JSON-RPC notification and logs the exact outbound JSON plus any write error.
  func notify(method: String, params: Any?) throws {
    var request: [String: Any] = ["method": method]
    if let params {
      request["params"] = params
    }
    let encoded = try encode(request)
    let requestJSON = String(data: encoded, encoding: .utf8) ?? "{}"
    var requestError: Error?
    defer {
      codexRPCLog.write(kind: "request", payload: requestJSON)
      if let requestError {
        codexRPCLog.write(kind: "error", payload: requestError.localizedDescription)
      }
      logRPC(
        event: "rpc_notification", method: method, requestID: nil,
        requestJSON: requestJSON, error: requestError
      )
    }
    do {
      try write(encoded)
    } catch {
      requestError = error
      throw error
    }
  }

  /// Stops the child exactly once, then logs its stderr and exit state even after a failed launch.
  /// - Parameters:
  ///   - reason: Identifies normal query cleanup, timeout cancellation, or launch failure.
  ///   - error: Original launch error retained in the private diagnostic record.
  func close(reason: String = "query_finished", error: Error? = nil) {
    closeLock.lock()
    defer { closeLock.unlock() }
    if isClosed {
      return
    }
    isClosed = true

    defer {
      try? diagnosticsOutput.close()
      logDiagnostics(reason: reason, error: error)
      try? FileManager.default.removeItem(at: diagnosticsURL)
    }
    input.closeFile()
    output.closeFile()
    guard hasLaunched else {
      return
    }
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(1)
      while process.isRunning, Date() < deadline {
        usleep(20_000)
      }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
  }

  /// Writes one JSON diagnostic record after exit, without logging credentials or environment values.
  /// Retains the final 256 KiB of unusually large stderr output and explicitly reports truncation.
  private func logDiagnostics(reason: String, error: Error?) {
    var stderr = ""
    var byteCount: UInt64 = 0
    var readError: Error?
    let maximumBytes: UInt64 = 262_144
    do {
      let handle = try FileHandle(forReadingFrom: diagnosticsURL)
      defer { try? handle.close() }
      byteCount = try handle.seekToEnd()
      try handle.seek(toOffset: byteCount > maximumBytes ? byteCount - maximumBytes : 0)
      stderr = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    } catch {
      readError = error
    }
    let record: [String: Any] = [
      "sessionID": sessionID,
      "executable": process.executableURL?.path ?? "",
      "pid": hasLaunched ? Int(process.processIdentifier) as Any : NSNull(),
      "exitCode": hasLaunched ? Int(process.terminationStatus) as Any : NSNull(),
      "terminationReason": hasLaunched
        ? (process.terminationReason == .exit ? "exit" : "signal") as Any : NSNull(),
      "shutdownReason": reason,
      "timedOut": reason == "timeout",
      "durationSeconds": Date().timeIntervalSince(startedAt),
      "stderr": stderr,
      "stderrByteCount": byteCount,
      "stderrTruncated": byteCount > maximumBytes,
      "stderrReadError": readError.map { $0.localizedDescription as Any } ?? NSNull(),
      "error": error.map { $0.localizedDescription as Any } ?? NSNull(),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    {
      codexRPCLog.write(kind: "app_server", payload: json)
      diagnostics?.write(kind: "app_server", payload: json)
    }
  }

  /// Logs faithful wire JSON as strings, with session/request correlation and numeric RPC errors.
  /// Called before transmission and from a defer installed before the RPC operation starts.
  private func logRPC(
    event: String, method: String, requestID: Int?, requestJSON: String,
    responseJSON: String? = nil, error: Error? = nil, duration: TimeInterval? = nil
  ) {
    var record: [String: Any] = [
      "event": event, "sessionID": sessionID, "method": method,
      "requestID": requestID.map { $0 as Any } ?? NSNull(),
      "requestJSON": requestJSON, "responseJSON": responseJSON.map { $0 as Any } ?? NSNull(),
      "error": error.map { $0.localizedDescription as Any } ?? NSNull(),
      "durationSeconds": duration.map { $0 as Any } ?? NSNull(),
    ]
    if let failure = error as? CodexQuotaError, case .rpc(let code, _) = failure {
      record["rpcErrorCode"] = code
    }
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return }
    codexRPCLog.write(kind: "rpc", payload: json)
    diagnostics?.write(kind: "rpc", payload: json)
  }

  /// Encodes a JSON object in stable key order so the logged request matches transmitted bytes.
  private func encode(_ object: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw CodexQuotaError.invalidResponse
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  /// Writes exactly one JSON line to App Server and rejects writes after shutdown.
  private func write(_ data: Data) throws {
    closeLock.lock()
    let closed = isClosed
    closeLock.unlock()
    guard !closed else {
      throw CodexQuotaError.timedOut
    }
    var line = data
    line.append(0x0A)
    do {
      try input.write(contentsOf: line)
    } catch {
      throw CodexQuotaError.transport("Codex 连接已关闭")
    }
  }

  /// Reads one complete JSON line while retaining any trailing bytes for the next response.
  private func readMessage() throws -> RPCMessage {
    while true {
      if let newline = readBuffer.firstIndex(of: 0x0A) {
        let line = readBuffer.prefix(upTo: newline)
        readBuffer.removeSubrange(...newline)
        guard !line.isEmpty,
          let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
          let raw = String(data: line, encoding: .utf8)
        else {
          throw CodexQuotaError.invalidResponse
        }
        return RPCMessage(object: object, rawJSON: raw)
      }
      let chunk = output.availableData
      guard !chunk.isEmpty else {
        throw CodexQuotaError.transport("Codex 连接已关闭")
      }
      readBuffer.append(chunk)
      guard readBuffer.count <= 1_048_576 else {
        throw CodexQuotaError.invalidResponse
      }
    }
  }

  /// Refuses unexpected server-initiated requests so account-only reads cannot invoke tools.
  private func refuseServerRequest(id: Int) throws {
    try write(
      encode([
        "id": id,
        "error": [
          "code": -32601,
          "message": "Account-only client",
        ],
      ])
    )
  }
}

/// Preserves both parsed content and the exact JSON line received from App Server.
private struct RPCMessage {
  /// Parsed JSON-RPC object used for request routing and result extraction.
  let object: [String: Any]

  /// Original response line written to the RPC log without re-serialization.
  let rawJSON: String
}

/// Appends complete RPC diagnostics to a private, size-bounded local file.
final class RPCFileLogger {
  /// Serializes RPC and CLI diagnostics through one process-wide rotation lock.
  static let shared = RPCFileLogger()
  /// Maximum retained byte count before the current file is moved to the next generation.
  private let maximumBytes: UInt64

  /// Number of complete rotated generations retained for later failure investigation.
  private let retainedGenerations: Int

  /// Lock that keeps request, response, and error lines from interleaving.
  private let lock = NSLock()

  /// File manager used for private directory creation, rotation, and metadata checks.
  private let fileManager = FileManager.default

  /// Exact path of the active RPC log under the current user's Library directory.
  private let logURL: URL

  /// ISO-8601 formatter used only while holding the logger lock.
  private let timestampFormatter: ISO8601DateFormatter

  /// Creates a configurable private log under `~/Library/Logs/CodexQuota`, defaulting to rpc.log.
  init(
    filename: String = "rpc.log", maximumBytes: UInt64 = 1_048_576,
    retainedGenerations: Int = 1
  ) {
    self.maximumBytes = maximumBytes
    self.retainedGenerations = max(1, retainedGenerations)
    let directory = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/CodexQuota", isDirectory: true)
    logURL = directory.appendingPathComponent(filename, isDirectory: false)
    timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  }

  /// Writes one full payload line and silently avoids affecting the RPC result on disk errors.
  func write(kind: String, payload: String) {
    lock.lock()
    defer { lock.unlock() }

    do {
      let directory = logURL.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try rotateIfNeeded()
      if !fileManager.fileExists(atPath: logURL.path) {
        guard
          fileManager.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
          )
        else {
          return
        }
      }

      let timestamp = timestampFormatter.string(from: Date())
      let line = "\(timestamp) \(kind)=\(payload)\n"
      let handle = try FileHandle(forWritingTo: logURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
      try handle.close()
    } catch {
      return
    }
  }

  /// Rotates bounded complete generations without truncating a request/response JSON payload.
  private func rotateIfNeeded() throws {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
      let size = attributes[.size] as? NSNumber,
      size.uint64Value >= maximumBytes
    else {
      return
    }

    let oldest = logURL.appendingPathExtension(String(retainedGenerations))
    if fileManager.fileExists(atPath: oldest.path) {
      try fileManager.removeItem(at: oldest)
    }
    if retainedGenerations > 1 {
      for generation in stride(from: retainedGenerations - 1, through: 1, by: -1) {
        let source = logURL.appendingPathExtension(String(generation))
        if fileManager.fileExists(atPath: source.path) {
          try fileManager.moveItem(
            at: source, to: logURL.appendingPathExtension(String(generation + 1))
          )
        }
      }
    }
    try fileManager.moveItem(at: logURL, to: logURL.appendingPathExtension("1"))
  }
}

/// Thread-safe shutdown hook for the single bounded automatic-consumption child process.
final class ResetCreditConsumptionCancellation {
  /// Protects registration and cancellation without holding a lock during child teardown.
  private let lock = NSLock()
  /// Once cancelled, even a later registration closes its child immediately.
  private var cancelled = false
  /// Registered native child teardown, cleared when normal RPC cleanup finishes.
  private var closeChild: (() -> Void)?

  /// Reads cancellation state before launching any automatic child.
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  /// Installs cleanup and handles shutdown that happened before the child was launched.
  func register(_ closeChild: @escaping () -> Void) {
    lock.lock()
    let shouldClose = cancelled
    if !shouldClose { self.closeChild = closeChild }
    lock.unlock()
    if shouldClose { closeChild() }
  }

  /// Removes the completed child's cleanup closure without reopening a cancelled operation.
  func clear() {
    lock.lock()
    closeChild = nil
    lock.unlock()
  }

  /// Cancels queued work or synchronously closes an active child, preserving durable pending state.
  func cancel() {
    lock.lock()
    cancelled = true
    let cleanup = closeChild
    closeChild = nil
    lock.unlock()
    cleanup?()
  }
}
