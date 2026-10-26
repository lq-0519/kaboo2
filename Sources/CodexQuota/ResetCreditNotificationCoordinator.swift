import Foundation
import UserNotifications

/// Identifies the two independent reminder preferences and their durable per-card history.
/// Slot identity stays unchanged when its lead time is edited, so edits never replay a sent slot.
enum ResetCreditReminderSlot: String, CaseIterable, Codable {
  /// First configurable reminder, enabled by default twelve hours before expiry.
  case first

  /// Second configurable reminder, enabled by default one hour before expiry.
  case second

  /// Default positive whole-hour lead time used when no preference has been saved.
  var defaultHours: Int { self == .first ? 12 : 1 }
}

/// Immutable reminder configuration captured during one successful reset-credit refresh.
struct ResetCreditReminderSettings: Equatable {
  /// Stable slot used for preference lookup and duplicate suppression across app launches.
  let slot: ResetCreditReminderSlot

  /// User preference independent of the overall expiry-notification switch.
  let isEnabled: Bool

  /// Positive integer hours subtracted from the server-provided expiry instant.
  let hours: Int
}

/// Sends expiry alerts only when a successful credit refresh finds an eligible available card.
/// Shares the existing notification transport and permissions without installing timers or delegates.
final class ResetCreditNotificationCoordinator {
  /// Overall preference; absent values enable expiry alerts for existing and new installations.
  private static let enabledKey = "resetCreditExpiryNotificationsEnabled"

  /// Durable per-account, per-card slot history retained even when cards temporarily disappear.
  private static let historyKey = "resetCreditExpiryNotificationHistory.v1"

  /// Largest supported lead time, expressed in hours to keep field and stepper bounds identical.
  static let maximumReminderHours = 8_760

  /// Existing system notification transport, authorization state and faithful JSON delivery logger.
  private let notifications: QuotaNotificationCoordinator

  /// Preference storage for switches, whole-hour lead times and accepted notification history.
  private let defaults: UserDefaults

  /// Prevents overlapping refresh callbacks from submitting the same batch before history is saved.
  private var deliveryInFlight = false

  /// Overall saved preference, which remains enabled even if system notification permission is denied.
  var isEnabled: Bool {
    defaultEnabled(forKey: Self.enabledKey)
  }

  /// Binds expiry reminders to the app's existing notification coordinator and preference domain.
  init(notifications: QuotaNotificationCoordinator, defaults: UserDefaults = .standard) {
    self.notifications = notifications
    self.defaults = defaults
  }

  /// Reads one independent reminder, defaulting to enabled and accepting only positive whole hours.
  func settings(for slot: ResetCreditReminderSlot) -> ResetCreditReminderSettings {
    let storedHours = defaults.object(forKey: hoursKey(for: slot)) as? NSNumber
    let hours = storedHours.map { Self.clampHours($0.intValue) } ?? slot.defaultHours
    return ResetCreditReminderSettings(
      slot: slot,
      isEnabled: defaultEnabled(forKey: enabledKey(for: slot)),
      hours: hours
    )
  }

  /// Saves the overall switch without clearing history or checking retained card snapshots.
  func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.enabledKey)
  }

  /// Saves an individual switch without resetting sent-slot history or triggering a notification.
  func setReminderEnabled(_ enabled: Bool, for slot: ResetCreditReminderSlot) {
    defaults.set(enabled, forKey: enabledKey(for: slot))
  }

  /// Saves a clamped integer-hour threshold; the next successful refresh applies the new setting.
  func setReminderHours(_ hours: Int, for slot: ResetCreditReminderSlot) {
    defaults.set(Self.clampHours(hours), forKey: hoursKey(for: slot))
  }

  /// Evaluates only freshly fetched available cards and submits at most one merged immediate alert.
  /// The account check is repeated before submission so an asynchronous permission check cannot
  /// deliver another account's alert. Failed or blocked submissions remain eligible on later refreshes.
  func observe(
    snapshot: ResetCreditsSnapshot,
    accountID: String,
    isCurrentAccount: @escaping () -> Bool
  ) {
    guard isEnabled, !deliveryInFlight,
      !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      isCurrentAccount()
    else { return }

    let accountKey = QuotaResetDetector.accountKey(accountID)
    let configuration = ResetCreditReminderSlot.allCases.map { settings(for: $0) }
    let history = loadHistory()
    let now = Date()
    let reminders = snapshot.items.compactMap { credit -> ResetCreditExpiryReminder? in
      Self.reminder(
        for: credit,
        configuration: configuration,
        completedSlots: history.accounts[accountKey]?[credit.id] ?? [],
        now: now
      )
    }
    guard !reminders.isEmpty else { return }

    let content = UNMutableNotificationContent()
    content.title = reminders.count == 1
      ? "Codex 重置卡即将到期" : "\(reminders.count) 张 Codex 重置卡即将到期"
    content.body = reminders.map {
      "\($0.credit.title)：将于 \(DisplayFormatter.exact($0.expiresAt)) 到期"
    }.joined(separator: "\n")
    content.threadIdentifier = "codex-reset-credit-expiry"
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "codex-reset-credit-expiry-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )

    deliveryInFlight = true
    notifications.submitNotification(
      request,
      isStillEligible: { [weak self] in
        guard let self else { return false }
        return self.isEnabled && isCurrentAccount()
          && configuration == ResetCreditReminderSlot.allCases.map { self.settings(for: $0) }
          && reminders.allSatisfy { $0.expiresAt > Date() }
      },
      completion: { [weak self] accepted in
        guard let self else { return }
        defer { self.deliveryInFlight = false }
        guard accepted else { return }
        var history = self.loadHistory()
        var account = history.accounts[accountKey] ?? [:]
        for reminder in reminders {
          account[reminder.credit.id, default: []].formUnion(reminder.coveredSlots)
        }
        history.accounts[accountKey] = account
        self.saveHistory(history)
      }
    )
  }

  /// Selects the most urgent enabled threshold already reached by an unexpired available card.
  /// When multiple thresholds were crossed, one alert covers them all. A previously sent urgent
  /// slot prevents a less urgent reminder from being replayed, including after settings changes.
  static func reminder(
    for credit: ResetCredit,
    configuration: [ResetCreditReminderSettings],
    completedSlots: Set<ResetCreditReminderSlot>,
    now: Date
  ) -> ResetCreditExpiryReminder? {
    guard credit.status == "available", !credit.id.isEmpty, let expiresAt = credit.expiresAt,
      expiresAt.timeIntervalSince1970.isFinite, expiresAt > now
    else { return nil }
    let remaining = expiresAt.timeIntervalSince(now)
    let reached = configuration.filter {
      $0.isEnabled && remaining <= TimeInterval($0.hours) * 3_600
    }.sorted {
      $0.hours == $1.hours ? $0.slot.rawValue < $1.slot.rawValue : $0.hours < $1.hours
    }
    guard let urgent = reached.first, !completedSlots.contains(urgent.slot) else { return nil }
    return ResetCreditExpiryReminder(
      credit: credit,
      expiresAt: expiresAt,
      coveredSlots: Set(reached.map { $0.slot })
    )
  }

  /// Applies identical positive whole-hour bounds to saved settings, typed values and steppers.
  private static func clampHours(_ hours: Int) -> Int {
    min(maximumReminderHours, max(1, hours))
  }

  /// Distinguishes an absent default-on preference from an explicitly saved false value.
  private func defaultEnabled(forKey key: String) -> Bool {
    defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
  }

  /// Returns the stable independent switch preference key for one reminder slot.
  private func enabledKey(for slot: ResetCreditReminderSlot) -> String {
    "resetCreditExpiryReminder.\(slot.rawValue).enabled"
  }

  /// Returns the integer-hour preference key without coupling it to duplicate-suppression identity.
  private func hoursKey(for slot: ResetCreditReminderSlot) -> String {
    "resetCreditExpiryReminder.\(slot.rawValue).hours"
  }

  /// Loads all account histories without forgetting another account when the active login changes.
  private func loadHistory() -> ResetCreditNotificationHistory {
    guard let data = defaults.data(forKey: Self.historyKey),
      let history = try? JSONDecoder().decode(ResetCreditNotificationHistory.self, from: data)
    else { return ResetCreditNotificationHistory(accounts: [:]) }
    return history
  }

  /// Persists only macOS-accepted reminders; expiry changes never erase a card's sent-slot record.
  private func saveHistory(_ history: ResetCreditNotificationHistory) {
    guard let data = try? JSONEncoder().encode(history) else { return }
    defaults.set(data, forKey: Self.historyKey)
  }
}

/// One freshly observed available card and the thresholds covered by a single immediate alert.
struct ResetCreditExpiryReminder {
  /// Current backend title and stable card ID used for content and account-scoped history.
  let credit: ResetCredit

  /// Valid unexpired server instant displayed in local time in the system notification.
  let expiresAt: Date

  /// All enabled thresholds already crossed, saved together after macOS accepts the alert.
  let coveredSlots: Set<ResetCreditReminderSlot>
}

/// Codable slot history retained across refreshes, preference changes, launches and account switches.
private struct ResetCreditNotificationHistory: Codable {
  /// Opaque account hash → backend card ID → reminder slots already accepted by macOS.
  var accounts: [String: [String: Set<ResetCreditReminderSlot>]]
}
