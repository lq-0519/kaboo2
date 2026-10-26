import Foundation

/// Centralizes stable percentage, countdown, freshness, and local-time presentation.
enum DisplayFormatter {
  /// Local calendar formatter that preserves the precise reset second.
  private static let exactDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
    return formatter
  }()

  /// Compact local clock formatter used for the latest-update footer.
  private static let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  /// Converts a remaining percentage to the integer form used by the status item.
  static func percent(_ value: Double?) -> String {
    guard let value, value.isFinite else {
      return "--%"
    }
    return "\(Int(value.rounded()))%"
  }

  /// Formats one quota window for the menu bar using the most useful compact precision.
  /// Five-hour values use `3h24`; seven-day values use `2d6` until the final day, then `3h45`.
  /// Hidden lower units are discarded, and the final minute stays at `0h0` without showing seconds.
  static func menuBarResetCountdown(
    for window: QuotaWindow?,
    now: Date = Date()
  ) -> String {
    guard let window else {
      return "—"
    }

    let remainingSeconds = window.resetsAt.timeIntervalSince(now)
    guard remainingSeconds > 0 else {
      return "待刷新"
    }

    switch window.kind {
    case .fiveHour:
      let totalMinutes = max(0, Int(remainingSeconds) / 60)
      return "\(totalMinutes / 60)h\(totalMinutes % 60)"
    case .sevenDay:
      if remainingSeconds < 86_400 {
        let totalMinutes = max(0, Int(remainingSeconds) / 60)
        return "\(totalMinutes / 60)h\(totalMinutes % 60)"
      }
      let totalHours = max(0, Int(remainingSeconds) / 3_600)
      return "\(totalHours / 24)d\(totalHours % 24)"
    }
  }

  /// Formats the menu-bar secondary row according to the persisted display mode.
  /// Absolute times use 24-hour `H:mm`; only seven-day resets outside today's local calendar
  /// date use `M/d`. Calendar comparison also handles tomorrow when fewer than 24 hours remain.
  /// The time zone is resolved on each call so a system time-zone change cannot leave cached text stale.
  static func menuBarResetTime(
    for window: QuotaWindow?,
    mode: MenuBarTimeDisplayMode,
    now: Date = Date(),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    if mode == .countdown {
      return menuBarResetCountdown(for: window, now: now)
    }
    guard let window else {
      return "—"
    }
    guard window.resetsAt > now else {
      return "待刷新"
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    if window.kind == .sevenDay && !calendar.isDate(window.resetsAt, inSameDayAs: now) {
      let components = calendar.dateComponents([.month, .day], from: window.resetsAt)
      guard let month = components.month, let day = components.day else {
        return "—"
      }
      return "\(month)/\(day)"
    }
    let components = calendar.dateComponents([.hour, .minute], from: window.resetsAt)
    guard let hour = components.hour, let minute = components.minute else {
      return "—"
    }
    return "\(hour):" + String(format: "%02d", minute)
  }

  /// Explains the selected time mode for hover and accessibility, including the full local reset
  /// date so a clock-only five-hour value is never ambiguous about today versus tomorrow.
  static func menuBarResetDescription(
    for window: QuotaWindow?,
    mode: MenuBarTimeDisplayMode,
    now: Date = Date()
  ) -> String {
    guard let window else {
      return "额度数据未知"
    }
    guard window.resetsAt > now else {
      return "已到重置时间，等待刷新"
    }
    let resetTime = "下次重置：\(exact(window.resetsAt))"
    if mode == .countdown {
      return "距离重置：\(duration(from: now, to: window.resetsAt))；\(resetTime)"
    }
    return resetTime
  }

  /// Formats an absolute instant in the current macOS timezone down to seconds.
  static func exact(_ date: Date?) -> String {
    guard let date else {
      return "未提供精确时间"
    }
    exactDateFormatter.timeZone = .current
    return exactDateFormatter.string(from: date)
  }

  /// Formats a quota reset as a live, second-resolution relative countdown.
  static func resetCountdown(until date: Date?, now: Date = Date()) -> String {
    guard let date else {
      return "重置时间未知"
    }
    guard date > now else {
      return "已到重置时间"
    }
    return "还有 \(duration(from: now, to: date))"
  }

  /// Formats a reset-credit expiry as a live, second-resolution relative countdown.
  static func expiryCountdown(until date: Date?, now: Date = Date()) -> String {
    guard let date else {
      return "长期有效"
    }
    guard date > now else {
      return "已到期"
    }
    return "还有 \(duration(from: now, to: date))到期"
  }

  /// Formats a successful fetch time without implying network activity from countdown ticks.
  static func freshness(_ date: Date?) -> String {
    guard let date else {
      return "尚未更新"
    }
    clockFormatter.timeZone = .current
    return "更新于 \(clockFormatter.string(from: date))"
  }

  /// Produces a compact duration with days, hours, minutes, and a zero-padded second.
  private static func duration(from start: Date, to end: Date) -> String {
    var seconds = max(0, Int(end.timeIntervalSince(start)))
    let days = seconds / 86_400
    seconds %= 86_400
    let hours = seconds / 3_600
    seconds %= 3_600
    let minutes = seconds / 60
    let remainder = seconds % 60

    var parts: [String] = []
    if days > 0 {
      parts.append("\(days)天")
    }
    if hours > 0 || days > 0 {
      parts.append("\(hours)小时")
    }
    if minutes > 0 || hours > 0 || days > 0 {
      parts.append("\(minutes)分")
    }
    parts.append(String(format: "%02d秒", remainder))
    return parts.joined(separator: " ")
  }
}
