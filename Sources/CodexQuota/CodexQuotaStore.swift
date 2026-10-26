import Foundation

/// Coordinates independent lightweight quota and low-frequency reset-credit refresh loops.
final class CodexQuotaStore {
  /// Persisted key for the user-selected HTTPS refresh interval.
  private static let refreshIntervalKey = "quotaRefreshIntervalSeconds"

  /// Persisted key for the low-frequency reset-credit refresh interval.
  private static let creditsRefreshIntervalKey = "creditsRefreshIntervalMinutes"

  /// Persisted key for the menu-bar percentage font size.
  private static let menuBarFontSizeKey = "menuBarFontSize"

  /// Persisted key controlling quota-driven menu-bar text and pie colors.
  private static let menuBarDynamicColorsKey = "menuBarDynamicColorsEnabled"

  /// Persisted selection shared by both menu-bar time rows; absent or unknown values use countdown.
  private static let menuBarTimeDisplayModeKey = "menuBarTimeDisplayMode"

  /// Independent style preference for the five-hour quota; missing values preserve the percentage default.
  private static let fiveHourMenuBarStyleKey = "fiveHourMenuBarDisplayStyle"

  /// Independent style preference for the seven-day quota; missing values preserve the pie default.
  private static let sevenDayMenuBarStyleKey = "sevenDayMenuBarDisplayStyle"

  /// Minimum interval that protects the account endpoint from accidental request storms.
  private static let minimumRefreshInterval = 10

  /// Maximum interval accepted by the compact numeric control.
  private static let maximumRefreshInterval = 86_400

  /// Minimum reset-credit interval that avoids repeatedly launching App Server.
  private static let minimumCreditsRefreshInterval = 1

  /// Maximum reset-credit interval accepted by the settings control.
  private static let maximumCreditsRefreshInterval = 60

  /// Smallest menu-bar font size offered by the settings page.
  private static let minimumMenuBarFontSize = 13

  /// Largest menu-bar font size offered by the settings page.
  private static let maximumMenuBarFontSize = 15

  /// Local reader for Codex OAuth material.
  private let authStore = CodexAuthStore()

  /// Reusable HTTPS service for five-hour and seven-day quota windows.
  private let usageService = CodexUsageService()

  /// One-shot App Server client used only on the reset-credit schedule.
  private let appServerClient = CodexAppServerClient()

  /// Account-scoped detector and macOS delivery coordinator for confirmed quota resets.
  private let notificationCoordinator = QuotaNotificationCoordinator()

  /// Refresh-only expiry reminders sharing the existing notification permissions and transport.
  private lazy var creditNotificationCoordinator = ResetCreditNotificationCoordinator(
    notifications: notificationCoordinator
  )

  /// Independent opt-in, cycle ledger and CLI sender for automatic reset greetings.
  private let greetingCoordinator = QuotaGreetingCoordinator()

  /// Independent default-off automatic card use, driven only by successful credit refreshes.
  private let creditAutoUseCoordinator = ResetCreditAutoUseCoordinator()

  /// Serial queue that prevents overlapping Codex child processes.
  private let appServerQueue = DispatchQueue(
    label: "com.local.CodexQuota.app-server",
    qos: .utility
  )

  /// Timer driving the user-configurable lightweight HTTPS refresh.
  private var usageTimer: Timer?

  /// Timer driving the fixed five-minute reset-credit refresh.
  private var creditsTimer: Timer?

  /// Guards duplicate startup when AppKit delivers repeated activation callbacks.
  private var hasStarted = false

  /// Tracks an in-flight HTTPS operation for button state and request deduplication.
  private var usageRefreshInFlight = false

  /// Tracks an in-flight App Server operation for button state and process deduplication.
  private var creditsRefreshInFlight = false

  /// Queues a display-only refresh when consumption finishes during an already active query.
  private var postConsumptionRefreshPending = false

  /// Requests a fresh quota query after an older in-flight HTTPS response finishes.
  private var postConsumptionUsageRefreshPending = false

  /// Prevents shutdown callbacks from scheduling new automatic work or background refreshes.
  private var isShuttingDown = false

  /// Latest successful subscription quota snapshot retained across transient errors.
  private(set) var quotaSnapshot: QuotaSnapshot?

  /// Latest successful reset-credit snapshot retained across transient errors.
  private(set) var creditsSnapshot: ResetCreditsSnapshot?

  /// Most recent quota error shown without discarding stale valid data.
  private(set) var quotaError: String?

  /// Most recent reset-credit error shown without discarding stale valid data.
  private(set) var creditsError: String?

  /// Main-thread callback used by both status-item and popover rendering.
  var onChange: (() -> Void)?

  /// Settings-only callback that updates delivery feedback without replacing an edited text field.
  var onGreetingChange: (() -> Void)?

  /// Settings-only callback updates automatic-use feedback without replacing the edited minute field.
  var onCreditAutoUseChange: (() -> Void)?

  /// Explicit opt-in; absent state defaults to off until the user enables it for the current login.
  var creditAutoUseEnabled: Bool { creditAutoUseCoordinator.isEnabled }

  /// Persisted integer-minute lead, independent of expiry reminder hour settings.
  var creditAutoUseLeadMinutes: Int { creditAutoUseCoordinator.leadMinutes }

  /// False when state storage is unsafe, another instance owns it, or shutdown has started.
  var creditAutoUseAvailable: Bool { creditAutoUseCoordinator.isAvailable }

  /// Current operation state and the latest confirmed card result for settings.
  var creditAutoUseStatus: String { creditAutoUseCoordinator.statusText }

  /// Explicit opt-in for sending a greeting after a confirmed quota-cycle change.
  var resetGreetingsEnabled: Bool { greetingCoordinator.isEnabled }

  /// A manual test must not overwrite a pending automatic job or an unreviewed execution.
  var canSendResetGreetingTest: Bool { greetingCoordinator.canSendTest }

  /// User-facing background state, measured usage and the most recent confirmed model response.
  var resetGreetingStatus: String { greetingCoordinator.statusText }

  /// Indicates whether a manual or automatic CLI submission is executing.
  var isSendingGreeting: Bool { greetingCoordinator.isSending }

  /// Disables sender controls after a persistent-state or competing-instance failure.
  var resetGreetingsAvailable: Bool { greetingCoordinator.isAvailable }

  /// Exposes an uncertain prior submission for explicit acknowledgement in settings.
  var resetGreetingNeedsReview: Bool { greetingCoordinator.needsReview }

  /// Indicates whether either independent refresh path is currently active.
  var isRefreshing: Bool {
    usageRefreshInFlight || creditsRefreshInFlight
  }

  /// Current persisted HTTPS refresh interval expressed in whole seconds.
  var refreshIntervalSeconds: Int {
    let stored = UserDefaults.standard.integer(forKey: Self.refreshIntervalKey)
    return Self.clampInterval(stored == 0 ? 60 : stored)
  }

  /// Current persisted reset-credit refresh interval expressed in whole minutes.
  var creditsRefreshIntervalMinutes: Int {
    let stored = UserDefaults.standard.integer(forKey: Self.creditsRefreshIntervalKey)
    return Self.clampCreditsInterval(stored == 0 ? 5 : stored)
  }

  /// Current persisted menu-bar font size expressed in whole points.
  var menuBarFontSize: Int {
    let stored = UserDefaults.standard.integer(forKey: Self.menuBarFontSizeKey)
    return Self.clampMenuBarFontSize(stored == 0 ? 14 : stored)
  }

  /// Indicates whether menu-bar quota values use remaining-percentage status colors.
  var menuBarDynamicColorsEnabled: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Self.menuBarDynamicColorsKey) != nil else {
      return true
    }
    return defaults.bool(forKey: Self.menuBarDynamicColorsKey)
  }

  /// Current time-row preference, defaulting to countdown for existing installations or invalid values.
  var menuBarTimeDisplayMode: MenuBarTimeDisplayMode {
    let stored = UserDefaults.standard.string(forKey: Self.menuBarTimeDisplayModeKey)
    return stored.flatMap(MenuBarTimeDisplayMode.init(rawValue:)) ?? .countdown
  }

  /// Reads one quota's saved primary-row style without changing the other window's preference.
  /// Absent or unrecognized values preserve the original five-hour percentage and seven-day pie layout.
  func menuBarQuotaStyle(for kind: QuotaKind) -> MenuBarQuotaDisplayStyle {
    let stored = UserDefaults.standard.string(forKey: Self.menuBarQuotaStyleKey(for: kind))
    let defaultStyle: MenuBarQuotaDisplayStyle = kind == .fiveHour ? .percentage : .pie
    return stored.flatMap(MenuBarQuotaDisplayStyle.init(rawValue:)) ?? defaultStyle
  }

  /// Indicates whether quota reset alerts were explicitly enabled inside the app.
  var resetNotificationsEnabled: Bool {
    notificationCoordinator.isEnabled
  }

  /// Latest macOS notification permission state rendered by the settings window.
  var resetNotificationAuthorizationState: QuotaNotificationAuthorizationState {
    notificationCoordinator.authorizationState
  }

  /// Default-enabled expiry preference, independent of the quota-reset notification switch.
  var creditExpiryNotificationsEnabled: Bool { creditNotificationCoordinator.isEnabled }

  /// Settings-only callback that refreshes permission feedback without replacing edited hour fields.
  var onNotificationChange: (() -> Void)?

  /// Returns one reminder's persisted independent switch and positive whole-hour threshold.
  func creditExpiryReminderSettings(for slot: ResetCreditReminderSlot) -> ResetCreditReminderSettings {
    creditNotificationCoordinator.settings(for: slot)
  }

  /// Creates the store and forwards asynchronous permission changes to shared UI rendering.
  init() {
    notificationCoordinator.onAuthorizationStatusChange = { [weak self] in
      self?.onChange?()
      self?.onNotificationChange?()
    }
    greetingCoordinator.onChange = { [weak self] in
      self?.onChange?()
      self?.onGreetingChange?()
    }
    greetingCoordinator.onNeedsFreshSnapshot = { [weak self] in self?.refreshUsage() }
    creditAutoUseCoordinator.onChange = { [weak self] in self?.onCreditAutoUseChange?() }
    creditAutoUseCoordinator.onConsumed = { [weak self] in
      guard let self, !self.isShuttingDown else { return }
      if self.usageRefreshInFlight {
        self.postConsumptionUsageRefreshPending = true
      } else {
        self.refreshUsage()
      }
      if self.creditsRefreshInFlight {
        self.postConsumptionRefreshPending = true
      } else {
        self.refreshCredits(allowAutomaticUse: false)
      }
    }
  }

  /// Starts both refresh loops and performs the initial live queries immediately.
  func start() {
    guard !hasStarted else {
      return
    }
    hasStarted = true
    notificationCoordinator.start()
    if creditNotificationCoordinator.isEnabled {
      notificationCoordinator.ensureAuthorization { _ in }
    }
    scheduleUsageTimer()
    scheduleCreditsTimer()
    refreshAll()
  }

  /// Refreshes quota and reset-credit data while each path independently deduplicates work.
  func refreshAll() {
    refreshUsage()
    refreshCredits()
  }

  /// Refreshes reset credits on popover open only when the configured interval has elapsed.
  func refreshCreditsIfStale(now: Date = Date()) {
    guard let fetchedAt = creditsSnapshot?.fetchedAt else {
      refreshCredits()
      return
    }
    let interval = TimeInterval(creditsRefreshIntervalMinutes * 60)
    if now.timeIntervalSince(fetchedAt) >= interval {
      refreshCredits()
    }
  }

  /// Applies a new interval, persists the clamped value, and reschedules only HTTPS work.
  func setRefreshInterval(seconds: Int) {
    let clamped = Self.clampInterval(seconds)
    UserDefaults.standard.set(clamped, forKey: Self.refreshIntervalKey)
    scheduleUsageTimer()
    onChange?()
  }

  /// Persists a reset-credit interval and reschedules only the App Server timer.
  func setCreditsRefreshInterval(minutes: Int) {
    let clamped = Self.clampCreditsInterval(minutes)
    UserDefaults.standard.set(clamped, forKey: Self.creditsRefreshIntervalKey)
    scheduleCreditsTimer()
    onChange?()
  }

  /// Persists a menu-bar font size and immediately asks the status item to redraw.
  func setMenuBarFontSize(_ size: Int) {
    let clamped = Self.clampMenuBarFontSize(size)
    UserDefaults.standard.set(clamped, forKey: Self.menuBarFontSizeKey)
    onChange?()
  }

  /// Persists quota-driven menu-bar coloring and immediately redraws the status item.
  func setMenuBarDynamicColorsEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.menuBarDynamicColorsKey)
    onChange?()
  }

  /// Saves the chosen time meaning and immediately redraws both quota rows without fetching data.
  func setMenuBarTimeDisplayMode(_ mode: MenuBarTimeDisplayMode) {
    UserDefaults.standard.set(mode.rawValue, forKey: Self.menuBarTimeDisplayModeKey)
    onChange?()
  }

  /// Saves only the selected quota's primary-row style and immediately requests a local redraw.
  /// This display preference neither fetches quota data nor changes the refresh or reset-time schedules.
  func setMenuBarQuotaStyle(_ style: MenuBarQuotaDisplayStyle, for kind: QuotaKind) {
    UserDefaults.standard.set(style.rawValue, forKey: Self.menuBarQuotaStyleKey(for: kind))
    onChange?()
  }

  /// Applies an explicit reset-notification preference and returns the effective result.
  func setResetNotificationsEnabled(
    _ enabled: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    notificationCoordinator.setEnabled(enabled) { [weak self] effectiveValue in
      self?.onChange?()
      completion(effectiveValue)
    }
  }

  /// Reloads notification authorization after System Settings may have changed it.
  func refreshResetNotificationAuthorizationStatus(
    completion: (() -> Void)? = nil
  ) {
    notificationCoordinator.refreshAuthorizationStatus(completion: completion)
  }

  /// Opens the app-specific macOS notification settings pane for denied permission.
  func openResetNotificationSystemSettings() {
    notificationCoordinator.openSystemSettings()
  }

  /// Saves the overall expiry preference and requests shared system permission when enabling it.
  /// Preference changes never check cached cards or fetch data; reminders wait for the next refresh.
  func setCreditExpiryNotificationsEnabled(
    _ enabled: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    creditNotificationCoordinator.setEnabled(enabled)
    onNotificationChange?()
    guard enabled else {
      completion(false)
      return
    }
    notificationCoordinator.ensureAuthorization(completion: completion)
  }

  /// Saves one expiry reminder switch without clearing its per-card notification history.
  func setCreditExpiryReminderEnabled(_ enabled: Bool, for slot: ResetCreditReminderSlot) {
    creditNotificationCoordinator.setReminderEnabled(enabled, for: slot)
    onNotificationChange?()
  }

  /// Saves an integer-hour lead time applied only by the next successful reset-credit refresh.
  func setCreditExpiryReminderHours(_ hours: Int, for slot: ResetCreditReminderSlot) {
    creditNotificationCoordinator.setReminderHours(hours, for: slot)
  }

  /// Binds an explicit enable to the current login; no immediate check or consume is performed.
  func setCreditAutoUseEnabled(_ enabled: Bool) throws {
    let auth = enabled ? try authStore.load() : nil
    try creditAutoUseCoordinator.setEnabled(enabled, auth: auth)
  }

  /// Saves integer minutes for the next successful refresh without using stale cached cards.
  func setCreditAutoUseLeadMinutes(_ minutes: Int) throws {
    try creditAutoUseCoordinator.setLeadMinutes(minutes)
  }

  /// Persists the greeting switch and seeds a fresh account-bound baseline after enabling it.
  func setResetGreetingsEnabled(_ enabled: Bool) throws {
    let auth: CodexAuth?
    if enabled { auth = try authStore.load() } else { auth = nil }
    try greetingCoordinator.setEnabled(enabled, auth: auth)
    if enabled { refreshUsage() }
  }

  /// Sends one explicitly requested test greeting independently of the automatic opt-in.
  func sendResetGreetingTest() throws {
    try greetingCoordinator.sendTest(auth: authStore.load())
  }

  /// Clears an inspected uncertain result and resumes from a fresh baseline without replaying it.
  func acknowledgeResetGreetingReview() throws {
    try greetingCoordinator.acknowledgeReview()
    if resetGreetingsEnabled { refreshUsage() }
  }

  /// Stops both refresh loops and automatic workers, retaining all ambiguous request identities.
  func shutdown() {
    isShuttingDown = true
    usageTimer?.invalidate()
    creditsTimer?.invalidate()
    creditAutoUseCoordinator.shutdown()
    greetingCoordinator.shutdown()
  }

  /// Performs one lightweight authenticated HTTPS fetch unless another is already active.
  private func refreshUsage() {
    guard !isShuttingDown, !usageRefreshInFlight else {
      return
    }
    let auth: CodexAuth
    do {
      auth = try authStore.load()
    } catch {
      quotaError = message(for: error, fallback: "额度查询失败")
      onChange?()
      return
    }

    usageRefreshInFlight = true
    onChange?()
    usageService.fetch(auth: auth) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else {
          return
        }
        self.usageRefreshInFlight = false
        guard !self.isShuttingDown else { return }
        switch result {
        case .success(let snapshot):
          self.notificationCoordinator.observe(
            snapshot: snapshot,
            accountID: auth.accountID
          )
          self.greetingCoordinator.observe(snapshot: snapshot, auth: auth)
          self.quotaSnapshot = snapshot
          self.quotaError = nil
        case .failure(let error):
          self.quotaError = self.message(for: error, fallback: "额度查询失败")
        }
        self.onChange?()
        if self.postConsumptionUsageRefreshPending {
          self.postConsumptionUsageRefreshPending = false
          self.refreshUsage()
        }
      }
    }
  }

  /// Performs a low-frequency query and checks automation only after a successful fresh snapshot.
  /// Display-only post-consumption queries suppress automatic selection to avoid cascading cards.
  private func refreshCredits(allowAutomaticUse: Bool = true) {
    guard !isShuttingDown, !creditsRefreshInFlight else {
      return
    }
    let auth: CodexAuth
    do {
      auth = try authStore.load()
    } catch {
      creditsError = message(for: error, fallback: "重置卡查询失败")
      creditAutoUseCoordinator.reportRefreshFailure(error)
      onChange?()
      return
    }

    creditsRefreshInFlight = true
    onChange?()
    appServerQueue.async { [weak self] in
      guard let self else {
        return
      }
      let result: Result<ResetCreditsSnapshot, Error>
      do {
        result = .success(try self.appServerClient.readResetCredits(auth: auth))
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async {
        self.creditsRefreshInFlight = false
        guard !self.isShuttingDown else { return }
        switch result {
        case .success(let snapshot):
          self.creditNotificationCoordinator.observe(
            snapshot: snapshot,
            accountID: auth.accountID,
            isCurrentAccount: { [weak self] in
              guard let self, let currentAuth = try? self.authStore.load() else { return false }
              return currentAuth.accountID == auth.accountID && currentAuth.authPath == auth.authPath
            }
          )
          self.creditsSnapshot = snapshot
          self.creditsError = nil
          if allowAutomaticUse, !self.postConsumptionRefreshPending {
            self.creditAutoUseCoordinator.observe(
              snapshot: snapshot, auth: auth, client: self.appServerClient,
              queue: self.appServerQueue
            )
          }
        case .failure(let error):
          self.creditsError = self.message(for: error, fallback: "重置卡查询失败")
          self.creditAutoUseCoordinator.reportRefreshFailure(error)
        }
        self.onChange?()
        if self.postConsumptionRefreshPending {
          self.postConsumptionRefreshPending = false
          self.refreshCredits(allowAutomaticUse: false)
        }
      }
    }
  }

  /// Replaces the HTTPS timer and grants tolerance so macOS can coalesce wakeups.
  private func scheduleUsageTimer() {
    usageTimer?.invalidate()
    let timer = Timer.scheduledTimer(
      withTimeInterval: TimeInterval(refreshIntervalSeconds),
      repeats: true
    ) { [weak self] _ in
      self?.refreshUsage()
    }
    timer.tolerance = min(5, TimeInterval(refreshIntervalSeconds) * 0.1)
    usageTimer = timer
  }

  /// Replaces the reset-credit timer with the user-selected low-frequency cadence.
  private func scheduleCreditsTimer() {
    creditsTimer?.invalidate()
    let interval = TimeInterval(creditsRefreshIntervalMinutes * 60)
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      self?.refreshCredits()
    }
    timer.tolerance = min(30, interval * 0.05)
    creditsTimer = timer
  }

  /// Produces concise Chinese diagnostics while suppressing transport implementation details.
  private func message(for error: Error, fallback: String) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription,
      !description.isEmpty
    {
      return description
    }
    return fallback
  }

  /// Clamps persisted or typed intervals to the resource-protection bounds.
  private static func clampInterval(_ value: Int) -> Int {
    min(maximumRefreshInterval, max(minimumRefreshInterval, value))
  }

  /// Clamps reset-credit minutes to the process-friendly settings range.
  private static func clampCreditsInterval(_ value: Int) -> Int {
    min(
      maximumCreditsRefreshInterval,
      max(minimumCreditsRefreshInterval, value)
    )
  }

  /// Maps a quota window to its stable, independent preference key for both reads and writes.
  private static func menuBarQuotaStyleKey(for kind: QuotaKind) -> String {
    switch kind {
    case .fiveHour:
      return fiveHourMenuBarStyleKey
    case .sevenDay:
      return sevenDayMenuBarStyleKey
    }
  }

  /// Clamps menu-bar typography to the three sizes supported by the layout.
  private static func clampMenuBarFontSize(_ value: Int) -> Int {
    min(maximumMenuBarFontSize, max(minimumMenuBarFontSize, value))
  }
}
