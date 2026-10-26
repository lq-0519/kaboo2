import AppKit
import Foundation
import UserNotifications

/// Summarizes the macOS notification authorization state needed by the settings UI.
enum QuotaNotificationAuthorizationState: Equatable {
  /// The current system state has not yet been loaded.
  case unknown

  /// The user has not yet responded to a notification permission request.
  case notDetermined

  /// macOS currently permits this app to deliver quota reset and credit expiry notifications.
  case authorized

  /// macOS has explicitly disabled notifications for this app.
  case denied
}

/// Detects confirmed quota-cycle changes and delivers account-scoped macOS notifications.
final class QuotaNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
  /// Persisted opt-in key; absence intentionally means notifications are disabled.
  private static let enabledKey = "quotaResetNotificationsEnabled"

  /// Persisted account baselines used to detect resets across launches and sleep.
  private static let baselinesKey = "quotaResetNotificationBaselines.v1"

  /// Permits small upstream timestamp corrections without treating them as a new cycle.
  private static let resetAdvanceTolerance = QuotaResetDetector.timestampTolerance

  /// System notification center used for authorization checks and immediate delivery.
  private let notificationCenter: UNUserNotificationCenter

  /// Preference store containing the opt-in and non-sensitive hashed account baselines.
  private let defaults: UserDefaults

  /// Most recently observed macOS authorization state for settings presentation.
  private(set) var authorizationState: QuotaNotificationAuthorizationState = .unknown

  /// Keeps permission checks and notification submission serial while their callbacks are pending.
  /// Reset baselines remain unchanged during this interval so a failed attempt can be retried.
  private var deliveryInFlight = false

  /// Coalesces simultaneous permission requests from reset and expiry settings into one system prompt.
  private var authorizationCompletions: [(Bool) -> Void] = []

  /// Main-thread callback used when System Settings changes notification authorization.
  var onAuthorizationStatusChange: (() -> Void)?

  /// Indicates whether the user explicitly enabled reset notifications inside this app.
  var isEnabled: Bool {
    defaults.bool(forKey: Self.enabledKey)
  }

  /// Creates a coordinator with the process notification center and standard preferences.
  init(
    notificationCenter: UNUserNotificationCenter = .current(),
    defaults: UserDefaults = .standard
  ) {
    self.notificationCenter = notificationCenter
    self.defaults = defaults
    super.init()
  }

  /// Installs foreground presentation behavior and loads the current system permission.
  func start() {
    notificationCenter.delegate = self
    refreshAuthorizationStatus()
  }

  /// Reloads macOS authorization so a retained settings window reflects external changes.
  func refreshAuthorizationStatus(completion: (() -> Void)? = nil) {
    notificationCenter.getNotificationSettings { [weak self] settings in
      guard let self else {
        return
      }
      let state = Self.authorizationState(for: settings.authorizationStatus)
      DispatchQueue.main.async {
        self.authorizationState = state
        self.onAuthorizationStatusChange?()
        completion?()
      }
    }
  }

  /// Applies the in-app opt-in, requesting system permission only after an explicit enable.
  func setEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
    guard enabled else {
      defaults.set(false, forKey: Self.enabledKey)
      DispatchQueue.main.async {
        completion(false)
      }
      return
    }

    ensureAuthorization { [weak self] granted in
      self?.finishEnableRequest(granted: granted, completion: completion)
    }
  }

  /// Requests the shared macOS permission when needed without changing any feature preference.
  /// Called on the main thread for default-enabled expiry alerts or an explicit settings enable.
  /// Denied permission is reported without repeatedly prompting or clearing the expiry preference.
  func ensureAuthorization(completion: @escaping (Bool) -> Void) {
    authorizationCompletions.append(completion)
    guard authorizationCompletions.count == 1 else { return }
    notificationCenter.getNotificationSettings { [weak self] settings in
      guard let self else { return }
      switch settings.authorizationStatus {
      case .notDetermined:
        self.notificationCenter.requestAuthorization(options: [.alert, .sound]) {
          [weak self] granted, _ in
          self?.completeAuthorizationChecks(granted: granted)
        }
      default:
        self.completeAuthorizationChecks(
          granted: Self.authorizationState(for: settings.authorizationStatus) == .authorized
        )
      }
    }
  }

  /// Publishes the latest system state and completes all joined permission checks on the main thread.
  private func completeAuthorizationChecks(granted: Bool) {
    refreshAuthorizationStatus { [weak self] in
      guard let self else { return }
      let completions = self.authorizationCompletions
      self.authorizationCompletions.removeAll()
      completions.forEach { $0(granted) }
    }
  }

  /// Records one successful account snapshot and sends at most one merged reset alert.
  func observe(snapshot: QuotaSnapshot, accountID: String) {
    let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedAccountID.isEmpty else {
      return
    }

    let accountKey = Self.accountKey(for: normalizedAccountID)
    var state = loadPersistedState()

    guard state.activeAccountKey == accountKey else {
      state.activeAccountKey = accountKey
      state.accounts = [accountKey: AccountBaseline(snapshot: snapshot)]
      savePersistedState(state)
      return
    }

    var account = state.accounts[accountKey] ?? AccountBaseline(snapshot: snapshot)
    var detectedResets: [DetectedReset] = []
    let notificationEnabled = isEnabled

    if let current = snapshot.fiveHour {
      let result = updatedBaseline(
        previous: account.fiveHour,
        current: current,
        fetchedAt: snapshot.fetchedAt,
        notificationEnabled: notificationEnabled
      )
      account.fiveHour = result.baseline
      if result.shouldNotify {
        detectedResets.append(DetectedReset(kind: .fiveHour, window: current))
      }
    }

    if let current = snapshot.sevenDay {
      let result = updatedBaseline(
        previous: account.sevenDay,
        current: current,
        fetchedAt: snapshot.fetchedAt,
        notificationEnabled: notificationEnabled
      )
      account.sevenDay = result.baseline
      if result.shouldNotify {
        detectedResets.append(DetectedReset(kind: .sevenDay, window: current))
      }
    }

    state.accounts = [accountKey: account]
    savePersistedState(state)

    guard !detectedResets.isEmpty else {
      return
    }
    deliverNotification(for: detectedResets, accountKey: accountKey)
  }

  /// Opens this application's pane in macOS Notification settings when available.
  func openSystemSettings() {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.local.CodexQuota"
    let encodedBundleID =
      bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleID)"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  /// Presents a banner even when the accessory app or its settings window is active.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  /// Completes an authorization attempt on the main thread and persists only granted opt-in.
  private func finishEnableRequest(
    granted: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    defaults.set(granted, forKey: Self.enabledKey)
    refreshAuthorizationStatus {
      completion(granted)
    }
  }

  /// Maps the system enum to the small stable state surface consumed by the app.
  private static func authorizationState(
    for status: UNAuthorizationStatus
  ) -> QuotaNotificationAuthorizationState {
    switch status {
    case .notDetermined:
      return .notDetermined
    case .denied:
      return .denied
    case .authorized, .provisional:
      return .authorized
    @unknown default:
      return .unknown
    }
  }

  /// Produces a stable opaque account namespace without persisting the Codex account ID.
  private static func accountKey(for accountID: String) -> String {
    var digest: UInt64 = 14_695_981_039_346_656_037
    for byte in accountID.utf8 {
      digest ^= UInt64(byte)
      digest &*= 1_099_511_628_211
    }
    return String(format: "%016llx", digest)
  }

  /// Advances ordinary observations and identifies a confirmed, not-yet-notified new cycle.
  /// Retains the previous baseline for a pending alert until macOS accepts its submission.
  private func updatedBaseline(
    previous: WindowBaseline?,
    current: QuotaWindow,
    fetchedAt: Date,
    notificationEnabled: Bool
  ) -> (baseline: WindowBaseline, shouldNotify: Bool) {
    guard let previous else {
      return (
        WindowBaseline(
          resetsAt: current.resetsAt,
          remainingPercent: current.remainingPercent,
          lastNotifiedResetsAt: nil
        ),
        false
      )
    }

    let confirmedReset = QuotaResetDetector.didReset(
      previousReset: previous.resetsAt,
      previousRemaining: previous.remainingPercent,
      current: current,
      fetchedAt: fetchedAt)
    let alreadyNotified =
      previous.lastNotifiedResetsAt.map {
        abs($0.timeIntervalSince(current.resetsAt))
          <= Self.resetAdvanceTolerance
      } ?? false
    let shouldNotify =
      notificationEnabled
      && confirmedReset
      && !alreadyNotified

    if shouldNotify {
      return (previous, true)
    }

    return (
      WindowBaseline(
        resetsAt: current.resetsAt,
        remainingPercent: current.remainingPercent,
        lastNotifiedResetsAt: previous.lastNotifiedResetsAt
      ),
      false
    )
  }

  /// Builds one merged alert and checks current system authorization before submitting it.
  /// Only a successful submission advances notification history; blocked or failed attempts retry
  /// from their retained baselines, and account changes invalidate an outstanding attempt.
  private func deliverNotification(for resets: [DetectedReset], accountKey: String) {
    guard !deliveryInFlight else {
      return
    }
    deliveryInFlight = true

    let ordered = resets.sorted {
      Self.sortOrder(for: $0.kind) < Self.sortOrder(for: $1.kind)
    }
    let content = UNMutableNotificationContent()
    content.threadIdentifier = "codex-quota-resets"
    content.sound = .default

    if ordered.count > 1 {
      content.title = "Codex 额度已重置"
      content.body = ordered.map(Self.notificationLine(for:)).joined(separator: "\n")
    } else if let reset = ordered.first {
      content.title = "\(reset.kind.displayName)已重置"
      content.body = Self.notificationLine(for: reset)
    }

    let request = UNNotificationRequest(
      identifier: "codex-quota-reset-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    submitNotification(
      request,
      isStillEligible: { [weak self] in
        guard let self else { return false }
        return self.isEnabled && self.loadPersistedState().activeAccountKey == accountKey
      },
      completion: { [weak self] accepted in
        guard let self else { return }
        defer { self.deliveryInFlight = false }
        guard accepted else { return }
        self.recordAcceptedNotification(for: ordered, accountKey: accountKey)
      }
    )
  }

  /// Shared immediate notification transport for confirmed resets and freshly observed expiring cards.
  /// Rechecks permission and caller eligibility before submission, reports macOS queue acceptance on
  /// the main thread, and logs the exact content and error without introducing scheduled triggers.
  func submitNotification(
    _ request: UNNotificationRequest,
    isStillEligible: @escaping () -> Bool,
    completion: @escaping (Bool) -> Void
  ) {
    notificationCenter.getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self else {
          return
        }
        let authorizationState = Self.authorizationState(for: settings.authorizationStatus)
        self.authorizationState = authorizationState
        self.onAuthorizationStatusChange?()

        guard authorizationState == .authorized, isStillEligible()
        else {
          self.logDelivery(
            request: request,
            authorizationStatus: settings.authorizationStatus,
            outcome: "skipped"
          )
          completion(false)
          return
        }

        self.logDelivery(
          request: request,
          authorizationStatus: settings.authorizationStatus,
          outcome: "submitting"
        )
        self.notificationCenter.add(request) { [weak self] error in
          DispatchQueue.main.async {
            guard let self else {
              return
            }
            self.logDelivery(
              request: request,
              authorizationStatus: settings.authorizationStatus,
              outcome: error == nil ? "accepted" : "failed",
              error: error
            )
            completion(error == nil)
          }
        }
      }
    }
  }

  /// Marks only the account and windows belonging to a successfully submitted alert.
  /// Reloads durable state to preserve other-window observations and account switches that
  /// occurred during submission, and never replaces a newer baseline with an older snapshot.
  private func recordAcceptedNotification(for resets: [DetectedReset], accountKey: String) {
    var state = loadPersistedState()
    guard state.activeAccountKey == accountKey, var account = state.accounts[accountKey] else {
      return
    }

    for reset in resets {
      let previous = reset.kind == .fiveHour ? account.fiveHour : account.sevenDay
      let latest = previous.flatMap {
        $0.resetsAt > reset.window.resetsAt ? $0 : nil
      } ?? WindowBaseline(window: reset.window)
      let baseline = WindowBaseline(
        resetsAt: latest.resetsAt,
        remainingPercent: latest.remainingPercent,
        lastNotifiedResetsAt: max(
          previous?.lastNotifiedResetsAt ?? reset.window.resetsAt,
          reset.window.resetsAt
        )
      )
      switch reset.kind {
      case .fiveHour:
        account.fiveHour = baseline
      case .sevenDay:
        account.sevenDay = baseline
      }
    }
    state.accounts[accountKey] = account
    savePersistedState(state)
  }

  /// Records the actual request content, observed authorization and submission outcome as JSON.
  /// An accepted submission describes macOS queue acceptance, not confirmation of banner display.
  private func logDelivery(
    request: UNNotificationRequest,
    authorizationStatus: UNAuthorizationStatus,
    outcome: String,
    error: Error? = nil
  ) {
    let errorPayload: Any
    if let error {
      let systemError = error as NSError
      errorPayload = [
        "domain": systemError.domain,
        "code": systemError.code,
        "description": systemError.localizedDescription,
      ] as [String: Any]
    } else {
      errorPayload = NSNull()
    }
    let payload: [String: Any] = [
      "request": [
        "identifier": request.identifier,
        "title": request.content.title,
        "body": request.content.body,
        "threadIdentifier": request.content.threadIdentifier,
        "sound": "default",
        "trigger": NSNull(),
      ],
      "authorizationStatus": authorizationStatus.rawValue,
      "outcome": outcome,
      "error": errorPayload,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    {
      RPCFileLogger.shared.write(kind: "notification", payload: json)
    }
  }

  /// Formats one exact local-time notification line with the latest remaining percentage.
  private static func notificationLine(for reset: DetectedReset) -> String {
    let percentage = DisplayFormatter.percent(reset.window.remainingPercent)
    let nextReset = DisplayFormatter.exact(reset.window.resetsAt)
    return "\(reset.kind.displayName)：剩余 \(percentage)，下次重置 \(nextReset)"
  }

  /// Keeps merged notification details in the preferred five-hour then seven-day order.
  private static func sortOrder(for kind: QuotaKind) -> Int {
    switch kind {
    case .fiveHour:
      return 0
    case .sevenDay:
      return 1
    }
  }

  /// Decodes durable baselines and safely falls back to an empty first-run state.
  private func loadPersistedState() -> PersistedState {
    guard let data = defaults.data(forKey: Self.baselinesKey),
      let state = try? JSONDecoder().decode(PersistedState.self, from: data)
    else {
      return PersistedState(activeAccountKey: nil, accounts: [:])
    }
    return state
  }

  /// Encodes account baselines after every successful snapshot transition.
  private func savePersistedState(_ state: PersistedState) {
    guard let data = try? JSONEncoder().encode(state) else {
      return
    }
    defaults.set(data, forKey: Self.baselinesKey)
  }
}

/// Couples one detected quota kind with its latest successful window values.
private struct DetectedReset {
  /// Window kind used for notification title and merged ordering.
  let kind: QuotaKind

  /// Latest upstream values displayed in the notification body.
  let window: QuotaWindow
}

/// Durable reset-detection state for the account used by the latest successful request.
private struct PersistedState: Codable {
  /// Hash of the account used by the most recent successful quota request.
  var activeAccountKey: String?

  /// Active-account baseline keyed by an opaque digest rather than an account identifier.
  var accounts: [String: AccountBaseline]
}

/// Durable five-hour and seven-day baselines for one hashed account.
private struct AccountBaseline: Codable {
  /// Latest successful five-hour observation, when supplied by the backend.
  var fiveHour: WindowBaseline?

  /// Latest successful seven-day observation, when supplied by the backend.
  var sevenDay: WindowBaseline?

  /// Builds a fresh no-notification baseline when an account first appears or changes.
  init(snapshot: QuotaSnapshot) {
    fiveHour = snapshot.fiveHour.map(WindowBaseline.init(window:))
    sevenDay = snapshot.sevenDay.map(WindowBaseline.init(window:))
  }
}

/// Durable fields required to recognize a real transition into a new quota cycle.
/// Pending notifications retain the preceding cycle until their submission is accepted.
private struct WindowBaseline: Codable {
  /// Absolute reset baseline, advanced by an ordinary observation or accepted notification.
  let resetsAt: Date

  /// Remaining percentage at the retained baseline, used as secondary reset evidence.
  let remainingPercent: Double

  /// New-cycle reset time accepted by macOS for delivery, used to prevent duplicate submissions.
  let lastNotifiedResetsAt: Date?

  /// Creates an initial observation that deliberately cannot emit a notification.
  init(window: QuotaWindow) {
    resetsAt = window.resetsAt
    remainingPercent = window.remainingPercent
    lastNotifiedResetsAt = nil
  }

  /// Creates an updated observation while preserving explicit notification history.
  init(
    resetsAt: Date,
    remainingPercent: Double,
    lastNotifiedResetsAt: Date?
  ) {
    self.resetsAt = resetsAt
    self.remainingPercent = remainingPercent
    self.lastNotifiedResetsAt = lastNotifiedResetsAt
  }
}
