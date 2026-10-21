import Foundation

/// Describes the OAuth material read from Codex's local `auth.json` file.
struct CodexAuth {
  /// OAuth bearer used only for requests to the hard-coded ChatGPT host.
  let accessToken: String

  /// Workspace account identifier forwarded through the supported account headers.
  let accountID: String

  /// Absolute path of the Codex authentication file used to scope App Server.
  let authPath: String
}

/// Identifies one of the two rolling Codex subscription windows.
enum QuotaKind {
  /// Five-hour rolling usage window.
  case fiveHour

  /// Seven-day rolling usage window.
  case sevenDay

  /// Stable Chinese label displayed in the popover.
  var displayName: String {
    switch self {
    case .fiveHour:
      return "5 小时额度"
    case .sevenDay:
      return "7 天额度"
    }
  }
}

/// Selects the meaning of the secondary menu-bar row for both quota windows.
/// Raw values are persisted so the user's choice survives app restarts and future label changes.
enum MenuBarTimeDisplayMode: String, CaseIterable {
  /// Shows the remaining duration using the existing compact hour/minute and day/hour formats.
  case countdown

  /// Shows the local reset clock time, or a month/day for a seven-day reset after today.
  case resetTime

  /// Native settings label describing the displayed information rather than its implementation.
  var displayName: String {
    switch self {
    case .countdown:
      return "距离重置"
    case .resetTime:
      return "下次重置时间"
    }
  }
}

/// Normalized usage information for one Codex rate-limit window.
struct QuotaWindow {
  /// Semantic window type determined from the upstream duration.
  let kind: QuotaKind

  /// Percentage already consumed according to the upstream response.
  let usedPercent: Double

  /// Absolute reset instant represented in the current user's local timezone by the UI.
  let resetsAt: Date

  /// Remaining percentage clamped to the valid range expected by the menu bar.
  var remainingPercent: Double {
    min(100, max(0, 100 - usedPercent))
  }
}

/// Successful HTTPS snapshot containing both subscription windows.
struct QuotaSnapshot {
  /// Seven-day window, if the upstream response supplied it.
  let sevenDay: QuotaWindow?

  /// Five-hour window, if the upstream response supplied it.
  let fiveHour: QuotaWindow?

  /// Local completion time used to show freshness without another request.
  let fetchedAt: Date
}

/// Displayable details for one Codex rate-limit reset credit.
struct ResetCredit {
  /// Opaque backend identifier retained only for stable ordering and diagnostics.
  let id: String

  /// Backend-provided title, normalized to a useful fallback when absent.
  let title: String

  /// Backend state used to exclude non-available entries from the active list.
  let status: String

  /// Optional absolute expiry instant supplied as Unix seconds by App Server.
  let expiresAt: Date?
}

/// Successful App Server snapshot for reset-credit availability.
struct ResetCreditsSnapshot {
  /// Authoritative available count, which may exceed the number of detail rows.
  let availableCount: Int

  /// Available detail rows sorted by soonest expiry.
  let items: [ResetCredit]

  /// Local completion time used to report the age of the reset-credit snapshot.
  let fetchedAt: Date
}

/// User-visible failures emitted by local authentication and transport services.
enum CodexQuotaError: LocalizedError {
  /// Codex has no readable OAuth authentication file.
  case notSignedIn

  /// The authentication file exists but does not contain subscription credentials.
  case unsupportedAuthentication

  /// The upstream response does not contain the required quota fields.
  case invalidResponse

  /// A child process or network operation exceeded its bounded execution time.
  case timedOut

  /// No supported Codex executable could be found on the machine.
  case codexNotFound

  /// A transport returned a concise, already-sanitized diagnostic.
  case transport(String)

  /// Chinese error description shown directly in the compact popover.
  var errorDescription: String? {
    switch self {
    case .notSignedIn:
      return "未检测到 Codex 登录"
    case .unsupportedAuthentication:
      return "当前登录方式不支持订阅额度"
    case .invalidResponse:
      return "Codex 返回了无法识别的数据"
    case .timedOut:
      return "查询超时"
    case .codexNotFound:
      return "未找到 Codex"
    case .transport(let message):
      return message
    }
  }
}
