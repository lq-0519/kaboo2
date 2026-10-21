import Foundation

/// Fetches lightweight subscription usage directly from the pinned ChatGPT HTTPS endpoints.
final class CodexUsageService {
  /// Primary endpoint currently used by Codex subscription clients.
  private static let primaryURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

  /// Compatibility endpoint used only when the primary endpoint returns HTTP 404.
  private static let fallbackURL = URL(string: "https://chatgpt.com/api/codex/usage")!

  /// Reusable ephemeral session that avoids disk caches and reuses live TLS connections.
  private let session: URLSession

  /// Creates a low-retention URL session with bounded request and resource timeouts.
  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.connectionProxyDictionary = [:]
    session = URLSession(configuration: configuration)
  }

  /// Retrieves and normalizes both quota windows, falling back only for endpoint compatibility.
  func fetch(auth: CodexAuth, completion: @escaping (Result<QuotaSnapshot, Error>) -> Void) {
    perform(url: Self.primaryURL, auth: auth) { [weak self] result in
      switch result {
      case .success(let snapshot):
        completion(.success(snapshot))
      case .failure(let error as HTTPFailure) where error.statusCode == 404:
        guard let self else {
          completion(.failure(CodexQuotaError.transport("查询已取消")))
          return
        }
        self.perform(url: Self.fallbackURL, auth: auth, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  /// Executes one authenticated GET against a known host and parses a successful response.
  private func perform(
    url: URL,
    auth: CodexAuth,
    completion: @escaping (Result<QuotaSnapshot, Error>) -> Void
  ) {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 8
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("CodexQuota/1.0", forHTTPHeaderField: "User-Agent")
    request.setValue(auth.accountID, forHTTPHeaderField: "X-Account-Id")
    request.setValue(auth.accountID, forHTTPHeaderField: "ChatClaude-Account-Id")
    request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")

    session.dataTask(with: request) { data, response, error in
      if let error {
        completion(.failure(CodexQuotaError.transport(Self.networkMessage(for: error))))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completion(.failure(CodexQuotaError.invalidResponse))
        return
      }
      guard http.statusCode == 200 else {
        completion(.failure(HTTPFailure(statusCode: http.statusCode)))
        return
      }
      guard let data, data.count <= 65_536 else {
        completion(.failure(CodexQuotaError.invalidResponse))
        return
      }

      do {
        completion(.success(try Self.parse(data: data)))
      } catch {
        completion(.failure(error))
      }
    }.resume()
  }

  /// Converts the upstream transport slots into semantic five-hour and seven-day windows.
  private static func parse(data: Data) throws -> QuotaSnapshot {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rateLimit = root["rate_limit"] as? [String: Any]
    else {
      throw CodexQuotaError.invalidResponse
    }

    let candidates = [
      rateLimit["primary_window"] as? [String: Any],
      rateLimit["secondary_window"] as? [String: Any],
    ].compactMap { $0 }

    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    for candidate in candidates {
      guard let window = parseWindow(candidate) else {
        continue
      }
      switch window.kind {
      case .fiveHour:
        fiveHour = fiveHour ?? window
      case .sevenDay:
        sevenDay = sevenDay ?? window
      }
    }

    guard fiveHour != nil || sevenDay != nil else {
      throw CodexQuotaError.invalidResponse
    }
    return QuotaSnapshot(sevenDay: sevenDay, fiveHour: fiveHour, fetchedAt: Date())
  }

  /// Parses one rate-limit window and identifies its meaning from the reported duration.
  private static func parseWindow(_ object: [String: Any]) -> QuotaWindow? {
    guard let used = number(object["used_percent"]),
      let reset = number(object["reset_at"]),
      let duration = number(object["limit_window_seconds"])
    else {
      return nil
    }

    let kind: QuotaKind
    switch Int64(duration) {
    case 5 * 60 * 60:
      kind = .fiveHour
    case 7 * 24 * 60 * 60:
      kind = .sevenDay
    default:
      return nil
    }
    return QuotaWindow(
      kind: kind,
      usedPercent: used,
      resetsAt: Date(timeIntervalSince1970: reset)
    )
  }

  /// Converts JSON numeric representations to a common floating-point value.
  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  /// Maps URL loading failures to short messages without exposing request headers.
  private static func networkMessage(for error: Error) -> String {
    let code = (error as NSError).code
    if code == NSURLErrorTimedOut {
      return "额度查询超时"
    }
    if code == NSURLErrorNotConnectedToInternet {
      return "网络不可用"
    }
    return "额度查询失败"
  }
}

/// Internal HTTP status marker used to trigger the endpoint fallback safely.
private struct HTTPFailure: Error {
  /// Upstream HTTP status code without response-body or credential material.
  let statusCode: Int
}
