import CryptoKit
import Foundation

/// Reads only the Codex-owned authentication file required for local quota access.
final class CodexAuthStore {
  /// File manager used for deterministic path and readability checks.
  private let fileManager: FileManager

  /// Creates an authentication reader with an injectable file manager.
  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  /// 读取 OAuth 和工作区信息。额度查询可从同一次读取中提取历史账号摘要，且不会保留 ID token。
  func load(includeQuotaHistoryIdentity: Bool = false) throws -> CodexAuth {
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

    var historyKey: String?
    if includeQuotaHistoryIdentity,
      let token = tokens["id_token"] as? String,
      let claims = try? Self.identityClaims(from: token),
      let subject = claims["sub"] as? String, !subject.isEmpty
    {
      historyKey = try? Self.accountKey(subject: subject, accountID: accountID)
    }
    return CodexAuth(
      accessToken: accessToken,
      accountID: accountID,
      authPath: path,
      quotaHistoryAccountKey: historyKey
    )
  }

  /// 为自动用卡重新核对当前用户、邮箱和登录路径，缺少身份时暂停用卡。
  /// ID token 只在解码期间使用，不写入记录或日志。
  func autoUseIdentity(for auth: CodexAuth) throws -> CodexAutoUseIdentity {
    let current = try load()
    guard current.accountID == auth.accountID, current.authPath == auth.authPath else {
      throw CodexQuotaError.transport("Codex 账号已切换")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: current.authPath))
    guard data.count <= 1_048_576,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = root["tokens"] as? [String: Any],
      tokens["account_id"] as? String == auth.accountID,
      let token = tokens["id_token"] as? String
    else {
      throw CodexQuotaError.transport("无法核对 Codex 登录身份，自动使用已暂停")
    }
    guard let claims = try Self.identityClaims(from: token),
      let subject = claims["sub"] as? String, !subject.isEmpty,
      let email = claims["email"] as? String,
      !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CodexQuotaError.transport("缺少 Codex 用户身份，自动使用已暂停")
    }
    let canonicalPath = URL(fileURLWithPath: auth.authPath).resolvingSymlinksInPath().path
    let key = try Self.accountKey(subject: subject, accountID: auth.accountID)
    return CodexAutoUseIdentity(
      key: key, authPath: canonicalPath,
      email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
  }

  /// 临时解码本机登录文件的 ID token 声明，供提取账号摘要和核对用卡身份。
  private static func identityClaims(from token: String) throws -> [String: Any]? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { throw CodexQuotaError.invalidResponse }
    var payload = String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let decoded = Data(base64Encoded: payload) else { return nil }
    return try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
  }

  /// 将用户和工作区组合为稳定摘要，共用已有用卡记录的摘要算法，不持久化原始标识。
  private static func accountKey(subject: String, accountID: String) throws -> String {
    let binding = try JSONSerialization.data(withJSONObject: [subject, accountID])
    return SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined()
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
