import Foundation

/// Reads only the Codex-owned authentication file required for local quota access.
final class CodexAuthStore {
  /// File manager used for deterministic path and readability checks.
  private let fileManager: FileManager

  /// Creates an authentication reader with an injectable file manager.
  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  /// Loads OAuth and workspace identifiers without retaining refresh tokens or ID tokens.
  func load() throws -> CodexAuth {
    guard let path = authenticationCandidates().first(where: fileManager.isReadableFile(atPath:))
    else {
      throw CodexQuotaError.notSignedIn
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    guard data.count <= 1_048_576,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = root["tokens"] as? [String: Any]
    else {
      throw CodexQuotaError.invalidResponse
    }

    let accessToken =
      (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let accountID =
      (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !accessToken.isEmpty, !accountID.isEmpty else {
      if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
        throw CodexQuotaError.unsupportedAuthentication
      }
      throw CodexQuotaError.notSignedIn
    }

    return CodexAuth(accessToken: accessToken, accountID: accountID, authPath: path)
  }

  /// Returns the only authentication paths the app is permitted to inspect.
  private func authenticationCandidates() -> [String] {
    if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !codexHome.isEmpty
    {
      return [(codexHome as NSString).appendingPathComponent("auth.json")]
    }

    return [
      (fileManager.homeDirectoryForCurrentUser.path as NSString)
        .appendingPathComponent(".codex/auth.json")
    ]
  }
}
