import AppKit

/// Owns the status item, transient popover, and application-wide data store.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  /// Variable-width status item containing both quota values and the selected reset time presentation.
  private var statusItem: NSStatusItem!

  /// Observes effective menu-bar appearance so non-template status colors retain native contrast.
  private var statusAppearanceObservation: NSKeyValueObservation?

  /// Coalesces temporary appearance transitions produced while macOS snapshots the status item.
  private var statusAppearanceRefreshPending = false

  /// Last complete visual key used to avoid rebuilding the same image on local timer ticks.
  private var lastStatusPresentationKey = ""

  /// Local display-only timer that advances countdowns or switches dates at midnight without network calls.
  private var menuBarCountdownTimer: Timer?

  /// Refreshes local time formatting after time-zone, day or system-clock changes; removed on exit.
  private var timeChangeObservers: [NSObjectProtocol] = []

  /// Transient popover dismissed automatically when the user clicks elsewhere.
  private let popover = NSPopover()

  /// Long-lived coordinator for network, App Server, timers, and retained snapshots.
  private let store = CodexQuotaStore()

  /// Popover controller retained so store updates can render even while hidden.
  private lazy var popoverController: PopoverViewController = {
    let controller = PopoverViewController(store: store)
    controller.onOpenSettings = { [weak self] in
      self?.openSettings()
    }
    return controller
  }()

  /// Retained settings window that applies preferences immediately through the shared store.
  private lazy var settingsWindowController = SettingsWindowController(store: store)

  /// Mouse-only global monitor installed solely while the transient popover is visible.
  private var popoverDismissalMonitor: Any?

  /// Observes wake events so reset detection refreshes immediately after sleep.
  private var wakeObserver: NSObjectProtocol?

  /// Creates the menu-bar surface, binds updates, and starts live data loading.
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(togglePopover)
      button.sendAction(on: [.leftMouseUp])
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleNone
      statusAppearanceObservation = button.observe(
        \.effectiveAppearance,
        options: [.new]
      ) { [weak self] _, _ in
        guard let self, !self.statusAppearanceRefreshPending else {
          return
        }
        self.statusAppearanceRefreshPending = true
        DispatchQueue.main.async { [weak self] in
          guard let self else {
            return
          }
          self.statusAppearanceRefreshPending = false
          self.renderStatusItem()
        }
      }
    }

    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    popover.contentViewController = popoverController
    popover.contentSize = popoverController.preferredContentSize

    store.onChange = { [weak self] in
      self?.render()
    }
    render()
    store.start()
    startMenuBarCountdownTimer()
    observeTimeChanges()
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.renderStatusItem()
      self?.store.refreshAll()
    }
  }

  /// Removes timers and observations before the accessory process exits.
  func applicationWillTerminate(_ notification: Notification) {
    store.shutdown()
    stopPopoverDismissalMonitor()
    menuBarCountdownTimer?.invalidate()
    menuBarCountdownTimer = nil
    statusAppearanceObservation?.invalidate()
    statusAppearanceObservation = nil
    for observer in timeChangeObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    timeChangeObservers.removeAll()
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
  }

  /// Tears down outside-click monitoring after any transient or programmatic close.
  func popoverDidClose(_ notification: Notification) {
    stopPopoverDismissalMonitor()
  }

  /// Updates the always-visible status image and any loaded popover fields from one store snapshot.
  private func render() {
    renderStatusItem()
    popoverController.render()
  }

  /// Renders the two quota columns for one instant and skips image work when nothing visible changed.
  private func renderStatusItem(now: Date = Date()) {
    guard let button = statusItem.button else {
      return
    }
    let fiveHourWindow = store.quotaSnapshot?.fiveHour
    let sevenDayWindow = store.quotaSnapshot?.sevenDay
    let fiveHourTitle = DisplayFormatter.percent(fiveHourWindow?.remainingPercent)
    let sevenDayTitle = DisplayFormatter.percent(sevenDayWindow?.remainingPercent)
    let fiveHourStyle = store.menuBarQuotaStyle(for: .fiveHour)
    let sevenDayStyle = store.menuBarQuotaStyle(for: .sevenDay)
    let timeMode = store.menuBarTimeDisplayMode
    let fiveHourTime = DisplayFormatter.menuBarResetTime(
      for: fiveHourWindow,
      mode: timeMode,
      now: now
    )
    let sevenDayTime = DisplayFormatter.menuBarResetTime(
      for: sevenDayWindow,
      mode: timeMode,
      now: now
    )
    let dynamicColorsEnabled = store.menuBarDynamicColorsEnabled
    let presentationKey = [
      button.effectiveAppearance.name.rawValue,
      String(store.menuBarFontSize),
      String(dynamicColorsEnabled),
      timeMode.rawValue,
      fiveHourStyle.rawValue,
      sevenDayStyle.rawValue,
      fiveHourTitle,
      fiveHourTime,
      fiveHourWindow.map { String($0.remainingPercent) } ?? "nil",
      sevenDayTitle,
      sevenDayTime,
      sevenDayWindow.map { String($0.remainingPercent) } ?? "nil",
    ].joined(separator: "|")

    if presentationKey != lastStatusPresentationKey {
      var image: NSImage?
      button.effectiveAppearance.performAsCurrentDrawingAppearance {
        image = MenuBarQuotaImage.make(
          fiveHourWindow: fiveHourWindow,
          sevenDayWindow: sevenDayWindow,
          fiveHourStyle: fiveHourStyle,
          sevenDayStyle: sevenDayStyle,
          fiveHourTime: fiveHourTime,
          sevenDayTime: sevenDayTime,
          primaryFontSize: store.menuBarFontSize,
          dynamicColorsEnabled: dynamicColorsEnabled
        )
      }
      if let image {
        lastStatusPresentationKey = presentationKey
        button.title = ""
        button.image = image
        statusItem.length = image.size.width + 8
      }
    }

    let fiveHourDescription = DisplayFormatter.menuBarResetDescription(
      for: fiveHourWindow, mode: timeMode, now: now
    )
    let sevenDayDescription = DisplayFormatter.menuBarResetDescription(
      for: sevenDayWindow, mode: timeMode, now: now
    )
    button.toolTip =
      "5 小时剩余 \(fiveHourTitle)，\(fiveHourDescription)\n"
      + "7 天剩余 \(sevenDayTitle)，\(sevenDayDescription)"
    button.setAccessibilityLabel("Codex 额度")
    button.setAccessibilityValue(
      "5 小时额度剩余 \(fiveHourTitle)，\(fiveHourDescription)；"
        + "7 天额度剩余 \(sevenDayTitle)，\(sevenDayDescription)"
    )
  }

  /// Starts a coalescible local timer for minute changes, reset expiry and absolute-mode midnight rollover.
  private func startMenuBarCountdownTimer() {
    menuBarCountdownTimer?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
      [weak self] _ in
      self?.renderStatusItem()
    }
    timer.tolerance = 1
    menuBarCountdownTimer = timer
  }

  /// Observes calendar and system-time events so absolute times and today's date update immediately.
  /// These callbacks only render retained quota data and never cause an additional network request.
  private func observeTimeChanges() {
    for name in [
      NSNotification.Name.NSSystemTimeZoneDidChange,
      NSNotification.Name.NSCalendarDayChanged,
      NSNotification.Name.NSSystemClockDidChange,
    ] {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        self?.renderStatusItem()
        self?.popoverController.render()
      }
      timeChangeObservers.append(observer)
    }
  }

  /// Closes the transient popover before presenting the retained settings window.
  private func openSettings() {
    popover.performClose(nil)
    settingsWindowController.present()
  }

  /// Opens or closes the transient popover relative to the status-item button.
  @objc private func togglePopover() {
    guard let button = statusItem.button else {
      return
    }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      popoverController.render()
      popover.contentSize = popoverController.preferredContentSize
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      startPopoverDismissalMonitor()
    }
  }

  /// Installs a mouse-only global monitor so clicks in other applications dismiss the popover.
  private func startPopoverDismissalMonitor() {
    guard popoverDismissalMonitor == nil else {
      return
    }
    popoverDismissalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.popover.performClose(nil)
      }
    }
  }

  /// Removes the global mouse monitor without retaining it beyond popover visibility.
  private func stopPopoverDismissalMonitor() {
    guard let popoverDismissalMonitor else {
      return
    }
    NSEvent.removeMonitor(popoverDismissalMonitor)
    self.popoverDismissalMonitor = nil
  }
}
