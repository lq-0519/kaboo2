import Darwin
import Foundation

/// Locates a desktop-bundled CLI before launchers that may depend on a terminal's Node/PATH.
enum CodexExecutableLocator {
  /// Returns the first executable candidate without invoking a login shell or changing login state.
  static func locate(fileManager: FileManager = .default) throws -> String {
    let home = fileManager.homeDirectoryForCurrentUser.path
    var candidates = [
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
      "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
      "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
      "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
      "\(home)/.local/bin/codex",
      "\(home)/.npm-global/bin/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
    ]
    candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map { "\($0)/codex" }
    guard let executable = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
      throw CodexQuotaError.codexNotFound
    }
    return executable
  }
}

/// Describes whether a failed background run could already have consumed subscription usage.
struct CodexExecutionFailure: LocalizedError {
  /// Short actionable description suitable for the settings window.
  let message: String
  /// True when replaying could duplicate a request whose remote outcome is unknown.
  let isUncertain: Bool
  /// True only for failures known to occur before message submission and worth retrying.
  let isRetryable: Bool
  /// Exposes the same description through Foundation's error presentation.
  var errorDescription: String? { message }
}

/// Durable evidence of a completed model request, independent of desktop conversation storage.
struct CodexGreetingResult: Codable {
  /// Transient CLI execution identifier retained only for diagnostics, never resumed by the app.
  let threadID: String
  /// Final nonempty model response, shown directly in the utility's settings.
  let reply: String
  /// Explicit subscription model used for this request rather than an inherited provider default.
  let model: String
  /// Local time at which the completion event and successful process exit were both confirmed.
  let completedAt: Date
  /// Elapsed execution time, excluding the separate CLI capability check.
  let durationSeconds: TimeInterval
  /// Exact numeric usage fields reported by turn.completed, including cached tokens when provided.
  let usage: [String: Int]
}

/// Coordinates cancellation across the main-thread controls and serial background process runner.
final class CodexExecutionCancellation {
  /// Protects cancellation and process registration so a cancelled operation cannot launch later.
  private let lock = NSLock()
  /// Remains true after cancellation, including between capability checking and model execution.
  private var cancelled = false
  /// Only the currently registered subprocess can be terminated by this operation's controls.
  private var process: Process?
  /// Broadcast completion supports both the worker and bounded application-exit cleanup.
  private var finished: DispatchGroup?

  /// Reports cancellation without exposing mutable process state across queues.
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  /// Registers and launches atomically with respect to cancellation, avoiding a late orphan launch.
  func launch(_ process: Process, finished: DispatchGroup) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else {
      throw CodexExecutionFailure(message: "后台问候已取消，尚未提交", isUncertain: false, isRetryable: false)
    }
    try process.run()
    self.process = process
    self.finished = finished
  }

  /// Drops only this command's registration; the cancellation flag still governs subsequent commands.
  func clear(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if self.process === process {
      self.process = nil
      finished = nil
    }
  }

  /// Stops the active child, escalating after two seconds; shutdown can wait for bounded cleanup.
  func cancel(waitForExit: Bool = false) {
    lock.lock()
    cancelled = true
    let active = process
    let completion = finished
    lock.unlock()
    guard let active, active.isRunning else { return }
    active.terminate()
    let stop = {
      if active.isRunning { kill(active.processIdentifier, SIGKILL) }
    }
    if waitForExit {
      if completion?.wait(timeout: .now() + 2) == .timedOut { stop() }
      _ = completion?.wait(timeout: .now() + 1)
    } else {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: stop)
    }
  }
}

/// Completion contract shared by the live CLI runner and isolated state-transition verification.
protocol CodexGreetingExecuting {
  /// Executes one authenticated greeting or reports a failure with explicit replay safety.
  func send(auth: CodexAuth, cancellation: CodexExecutionCancellation) throws -> CodexGreetingResult
}

/// Executes one ephemeral model request without queueing, navigating, or resuming a desktop chat.
final class CodexExecClient: CodexGreetingExecuting {
  /// Keeps the verified general subscription model explicit instead of inheriting custom API routing.
  static let model = "gpt-6.1-sol"

  /// Returns only confirmed model completion; launches and partial output never count as success.
  func send(auth: CodexAuth, cancellation: CodexExecutionCancellation) throws -> CodexGreetingResult
  {
    let current: CodexAuth
    do { current = try CodexAuthStore().load() } catch {
      throw CodexExecutionFailure(
        message: "无法读取 Codex 登录信息，请重新登录后重试",
        isUncertain: false, isRetryable: false)
    }
    guard current.accountID == auth.accountID, current.authPath == auth.authPath else {
      throw CodexExecutionFailure(
        message: "Codex 账号已切换，请重新开启自动问候", isUncertain: false, isRetryable: false)
    }
    let executable: String
    do {
      executable = try CodexExecutableLocator.locate()
    } catch {
      throw CodexExecutionFailure(
        message: "未找到 Codex，请检查桌面应用是否已安装", isUncertain: false, isRetryable: true)
    }
    var environment = ProcessInfo.processInfo.environment
    for key in Array(environment.keys) {
      if key.hasPrefix("CODEX_") || key.hasPrefix("OPENAI_") || key.hasPrefix("OTEL_") {
        environment.removeValue(forKey: key)
      }
    }
    environment["CODEX_HOME"] = (auth.authPath as NSString).deletingLastPathComponent

    // Capability checks are read-only: any failure here is known to precede submission.
    do {
      let help = try run(
        executable, arguments: ["exec", "--help"], environment: environment,
        timeout: 12, cancellation: cancellation)
      guard help.status == 0, !help.timedOut, !cancellation.isCancelled,
        ["--ephemeral", "--ignore-user-config", "--json", "--skip-git-repo-check"].allSatisfy({
          help.output.contains($0)
        })
      else {
        throw CodexQuotaError.transport("当前 Codex 不支持所需后台执行参数")
      }
    } catch {
      throw CodexExecutionFailure(
        message: cancellation.isCancelled ? "后台问候已取消，尚未提交" : "无法使用 Codex 后台执行，请检查 CLI 版本和运行环境",
        isUncertain: false, isRetryable: false)
    }

    let result = try run(
      executable,
      arguments: [
        "exec", "--ephemeral", "--ignore-user-config", "--json", "--skip-git-repo-check",
        "--color", "never", "-s", "read-only", "-m", Self.model,
        "-c", "model_provider=\"openai\"", "-c", "forced_login_method=\"chatgpt\"",
        "-c", "approval_policy=\"never\"", "-c", "model_reasoning_effort=\"low\"",
        "你好，请只回复“你好”，不要调用任何工具。",
      ], environment: environment, timeout: 90, cancellation: cancellation)
    return try completedResult(from: result)
  }

  /// Parses the JSONL terminal contract, keeping token counts separate from quota percentages.
  private func completedResult(from result: CodexCommandResult) throws -> CodexGreetingResult {
    var threadID = ""
    var reply = ""
    var usage: [String: Int] = [:]
    var completed = false
    var failed = false
    var malformed = false
    var usedTools = false
    for line in result.output.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
        let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let type = event["type"] as? String
      else {
        malformed = true
        continue
      }
      switch type {
      case "thread.started": threadID = event["thread_id"] as? String ?? ""
      case "turn.failed": failed = true
      case "turn.completed":
        completed = true
        for (key, value) in event["usage"] as? [String: NSNumber] ?? [:] {
          usage[key] = value.intValue
        }
      case "item.started", "item.completed":
        if let item = event["item"] as? [String: Any], let itemType = item["type"] as? String {
          if type == "item.completed", itemType == "agent_message" {
            reply = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          }
          if ["command_execution", "file_change", "mcp_tool_call", "web_search"].contains(itemType)
          {
            usedTools = true
          }
        }
      default: break
      }
    }
    guard result.status == 0, completed, !failed, !malformed, !usedTools,
      UUID(uuidString: threadID) != nil, !reply.isEmpty,
      (usage["input_tokens"] ?? 0) > 0, (usage["output_tokens"] ?? 0) > 0
    else {
      let message: String
      if result.timedOut {
        message = "后台问候超时，结果待核实；请查看执行日志"
      } else if result.cancelled {
        message = "后台执行已停止，远端结果待核实；请查看执行日志"
      } else if usedTools {
        message = "问候执行出现工具调用，已暂停；请查看执行日志"
      } else {
        message = "未确认后台问候完成，结果待核实；请查看执行日志"
      }
      throw CodexExecutionFailure(message: message, isUncertain: true, isRetryable: false)
    }
    return CodexGreetingResult(
      threadID: threadID, reply: reply, model: Self.model, completedAt: Date(),
      durationSeconds: result.durationSeconds, usage: usage)
  }

  /// Runs without shell interpolation; private temporary output files avoid pipe deadlocks.
  /// The defer is registered before launch and faithfully logs arguments, output and failures.
  private func run(
    _ executable: String, arguments: [String], environment: [String: String],
    timeout: TimeInterval, cancellation: CodexExecutionCancellation
  ) throws -> CodexCommandResult {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-quota-exec-\(UUID().uuidString)", isDirectory: true)
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    let process = Process()
    let finished = DispatchGroup()
    let startedAt = Date()
    var launched = false
    var timedOut = false
    var commandError: Error?
    var stdoutHandle: FileHandle?
    var stderrHandle: FileHandle?
    defer {
      cancellation.clear(process)
      try? stdoutHandle?.close()
      try? stderrHandle?.close()
      let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
      let diagnostics = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
      let record: [String: Any] = [
        "executable": executable, "arguments": arguments,
        "stdout": output, "stderr": diagnostics,
        "exitCode": launched && !process.isRunning ? Int(process.terminationStatus) : NSNull(),
        "timedOut": timedOut, "cancelled": cancellation.isCancelled,
        "durationSeconds": Date().timeIntervalSince(startedAt),
        "error": commandError.map { $0.localizedDescription as Any } ?? NSNull(),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8)
      {
        RPCFileLogger.shared.write(kind: "exec", payload: json)
      }
      try? FileManager.default.removeItem(at: directory)
    }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let workspace = directory.appendingPathComponent("work", isDirectory: true)
      try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      for url in [stdoutURL, stderrURL] {
        guard
          FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CodexQuotaError.transport("无法创建发送日志") }
      }
      stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
      stderrHandle = try FileHandle(forWritingTo: stderrURL)
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.environment = environment
      process.currentDirectoryURL = workspace
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = stdoutHandle
      process.standardError = stderrHandle
      finished.enter()
      process.terminationHandler = { _ in finished.leave() }
      do { try cancellation.launch(process, finished: finished) } catch {
        finished.leave()
        throw error
      }
      launched = true
      if finished.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        cancellation.cancel(waitForExit: true)
        commandError = CodexQuotaError.transport("CLI 执行超时")
      } else if cancellation.isCancelled {
        commandError = CodexQuotaError.transport("CLI 执行已取消")
      }
      let output = try String(contentsOf: stdoutURL, encoding: .utf8)
      return CodexCommandResult(
        status: process.isRunning ? nil : process.terminationStatus, output: output,
        timedOut: timedOut, cancelled: cancellation.isCancelled,
        durationSeconds: Date().timeIntervalSince(startedAt))
    } catch {
      commandError = error
      if !launched {
        if let failure = error as? CodexExecutionFailure { throw failure }
        throw CodexExecutionFailure(
          message: "无法启动 Codex 后台执行进程", isUncertain: false, isRetryable: true)
      }
      throw error
    }
  }
}

/// Raw local command outcome; even a zero exit code must still satisfy model-completion parsing.
private struct CodexCommandResult {
  /// Nil means bounded termination could not confirm that the subprocess exited.
  let status: Int32?
  /// Unmodified JSONL output, also logged alongside stderr by the runner's defer.
  let output: String
  /// True when the command exceeded its own capability or inference deadline.
  let timedOut: Bool
  /// Records explicit cancellation even if it raced with normal completion.
  let cancelled: Bool
  /// Wall-clock duration used for the durable completion result.
  let durationSeconds: TimeInterval
}
