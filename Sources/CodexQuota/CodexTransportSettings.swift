import Foundation

/// User-selectable Responses transport; WebSocket retains Codex's built-in HTTP fallback.
enum CodexTransportMode: String, CaseIterable {
  /// Uses the built-in OpenAI provider and its normal WebSocket-first behavior.
  case webSocket
  /// Uses OpenAI authentication with Responses over HTTP/SSE, without attempting WebSocket.
  case http

  /// Human-readable selector text that does not promise a WebSocket-only connection.
  var displayName: String {
    switch self {
    case .webSocket: return "WebSocket 优先（默认）"
    case .http: return "HTTP 流式"
    }
  }
}

/// Saved configuration state, distinct from the transport of any already-running conversation.
struct CodexTransportSnapshot {
  /// Selected mode, or nil when another provider is outside this utility's scope.
  let mode: CodexTransportMode?
  /// Nonempty explanation prevents overwriting profiles, managed settings or custom providers.
  let restriction: String?
  /// Exact user configuration file, exposed only as a tooltip for locating the saved preference.
  let configPath: String
}

/// Edits only Codex's transport-related user keys through its comment-preserving config API.
/// No model request, login change, process restart or current-thread override is performed.
final class CodexTransportSettings {
  /// A private provider ID is required because modern Codex rejects overrides of `openai`.
  private static let httpProviderID = "codex_quota_http"

  /// OpenAI's normal authentication and endpoint selection are retained by omitting a base URL.
  /// Keeping the OpenAI name also preserves the built-in hosted-tool capability detection.
  private static let httpProvider: [String: Any] = [
    "name": "OpenAI",
    "wire_api": "responses",
    "requires_openai_auth": true,
    "supports_websockets": false,
  ]

  /// Codex home is injectable so verification can operate entirely in a disposable directory.
  private let homeURL: URL

  /// Optional executable override supports isolated compatibility checks without changing PATH.
  private let executableURL: URL?

  /// Chooses the same user configuration directory as Codex without reading authentication tokens.
  init(homeURL: URL? = nil, executableURL: URL? = nil) {
    let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    self.homeURL = homeURL ?? configuredHome.flatMap { value in
      value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    self.executableURL = executableURL
  }

  /// Reads current saved settings; opening the settings window never writes the Codex config.
  func read() throws -> CodexTransportSnapshot {
    try withSession { session in
      try inspect(session).snapshot
    }
  }

  /// Saves a deliberate user selection using one version-checked batch, preserving unrelated keys.
  /// Returning to WebSocket restores built-in OpenAI; the unused HTTP definition is retained
  /// so conversations created with that provider can still resolve their stored provider ID.
  func save(_ mode: CodexTransportMode) throws -> CodexTransportSnapshot {
    try withSession { session in
      let before = try inspect(session)
      if let restriction = before.snapshot.restriction {
        throw CodexQuotaError.transport(restriction)
      }
      guard before.snapshot.mode != mode else { return before.snapshot }

      let providerKey = "model_providers.\(Self.httpProviderID)"
      let edits: [[String: Any]]
      switch mode {
      case .http:
        edits = [
          ["keyPath": providerKey, "value": Self.httpProvider, "mergeStrategy": "replace"],
          ["keyPath": "model_provider", "value": Self.httpProviderID, "mergeStrategy": "replace"],
        ]
      case .webSocket:
        edits = [
          ["keyPath": "model_provider", "value": NSNull(), "mergeStrategy": "replace"],
        ]
      }
      let result = try session.call(
        method: "config/batchWrite",
        params: [
          "edits": edits,
          "filePath": before.snapshot.configPath,
          "expectedVersion": before.version,
          "reloadUserConfig": false,
        ]
      )
      guard result["status"] as? String == "ok" else {
        throw CodexQuotaError.transport("连接设置未保存，请重新读取后再试")
      }
      let after = try inspect(session).snapshot
      guard after.mode == mode, after.restriction == nil else {
        throw CodexQuotaError.transport("设置已写入，但被其他配置覆盖，请检查 Codex 配置")
      }
      return after
    }
  }

  /// Restricts editing to the built-in OpenAI configuration and this utility's exact HTTP provider.
  /// Uses the user layer's version so concurrent edits fail instead of replacing a newer config.
  private func inspect(_ session: AppServerSession) throws -> (
    snapshot: CodexTransportSnapshot, version: String
  ) {
    let response = try session.call(
      method: "config/read", params: ["includeLayers": true], redactResponse: true
    )
    guard let config = response["config"] as? [String: Any],
      let layers = response["layers"] as? [[String: Any]],
      let user = layers.first(where: {
        let name = $0["name"] as? [String: Any]
        return name?["type"] as? String == "user" && !(name?["profile"] is String)
      }),
      let version = user["version"] as? String,
      let name = user["name"] as? [String: Any], let path = name["file"] as? String
    else {
      throw CodexQuotaError.transport("当前 Codex 不支持读取连接配置，请更新后重试")
    }
    let providerID = config["model_provider"] as? String ?? "openai"
    // Inspect the raw user table, since the merged config materializes optional provider defaults.
    let userConfig = user["config"] as? [String: Any] ?? [:]
    let providers = userConfig["model_providers"] as? [String: Any] ?? [:]
    let ownedProvider = providers[Self.httpProviderID] as? [String: Any]
    let mode: CodexTransportMode? = providerID == "openai" ? .webSocket
      : (providerID == Self.httpProviderID ? .http : nil)
    let origins = response["origins"] as? [String: [String: Any]] ?? [:]
    let providerOrigin = origins["model_provider"]?["name"] as? [String: Any]
    let originType = providerOrigin?["type"] as? String
    let restriction: String?
    if let profile = config["profile"] as? String, !profile.isEmpty {
      restriction = "当前使用 Codex 配置方案，请先取消方案或在方案内设置连接方式"
    } else if let originType, originType != "user" {
      restriction = "连接设置由其他配置管理，暂不能在这里覆盖"
    } else if mode == nil {
      restriction = "当前使用自定义模型服务，暂不能在这里切换连接方式"
    } else if config["openai_base_url"] is String {
      restriction = "当前使用自定义模型地址，暂不能在这里切换连接方式"
    } else if let ownedProvider, !isOwnedProvider(ownedProvider) {
      restriction = "HTTP 连接配置已被手动修改，请先检查 Codex 配置"
    } else {
      restriction = nil
    }
    return (CodexTransportSnapshot(mode: mode, restriction: restriction, configPath: path), version)
  }

  /// Accepts only the provider created here; never replaces an unrelated object with the same ID.
  private func isOwnedProvider(_ provider: [String: Any]) -> Bool {
    let meaningful = provider.filter { !($0.value is NSNull) }
    return NSDictionary(dictionary: meaningful).isEqual(to: Self.httpProvider)
  }

  /// Starts a bounded local config-only App Server without reading auth or submitting inference.
  /// Secret-bearing config responses are redacted by the shared JSON-RPC session logger.
  private func withSession<T>(_ body: (AppServerSession) throws -> T) throws -> T {
    let executable = try executableURL
      ?? URL(fileURLWithPath: CodexExecutableLocator.locate())
    var environment = ProcessInfo.processInfo.environment
    for key in Array(environment.keys) {
      let upper = key.uppercased()
      if upper.hasPrefix("CODEX_") || upper.hasPrefix("OPENAI_") || upper.hasPrefix("OTEL_")
        || upper == "RUST_LOG"
      {
        environment.removeValue(forKey: key)
      }
    }
    environment["CODEX_HOME"] = homeURL.path
    let session = try AppServerSession(
      executableURL: executable,
      arguments: ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"],
      environment: environment
    )
    let timeout = DispatchWorkItem { session.close(reason: "timeout") }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
    defer {
      timeout.cancel()
      session.close()
    }
    _ = try session.call(
      method: "initialize",
      params: ["clientInfo": ["name": "codex_quota_transport", "version": "1.0.0"]]
    )
    try session.notify(method: "initialized", params: nil)
    return try body(session)
  }
}
