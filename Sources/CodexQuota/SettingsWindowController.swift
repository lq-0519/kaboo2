import AppKit

/// Retains the native settings window after it is closed so controls preserve focus and state.
final class SettingsWindowController: NSWindowController {
  /// Creates a compact utility window backed by the shared application store.
  init(store: CodexQuotaStore) {
    let viewController = SettingsViewController(store: store)
    let window = NSWindow(contentViewController: viewController)
    window.title = "Codex Quota 设置"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.setContentSize(NSSize(width: 460, height: 730))
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    super.init(window: window)
    viewController.resizeToFitContents()
  }

  /// Prevents construction from archived interface files because the window is programmatic.
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Brings the retained settings window to the active desktop and refreshes system state.
  func present() {
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// Renders immediate-save application, display, and refresh preferences.
final class SettingsViewController: NSViewController, NSTextFieldDelegate {
  /// Shared store that persists and applies application-level preferences.
  private let store: CodexQuotaStore

  /// Native login-item wrapper used only by the launch-at-login row.
  private let launchAtLogin = LaunchAtLoginManager()

  /// Switch reflecting the current macOS login-item registration state.
  private let launchSwitch = NSSwitch()

  /// Secondary status shown only for approval, errors, or unavailable service state.
  private let launchStatusLabel = NSTextField(labelWithString: "")

  /// Command that opens Login Items when system approval is required.
  private let openSystemSettingsButton = NSButton(
    title: "打开系统设置",
    target: nil,
    action: nil
  )

  /// Switch that requests notification permission only after an explicit user action.
  private let notificationSwitch = NSSwitch()

  /// Explains pending, missing or denied system authorization independently of the saved opt-in.
  private let notificationStatusLabel = NSTextField(labelWithString: "")

  /// Entire login feedback row, collapsed when neither status text nor a settings action is needed.
  /// Hiding the grid row removes its empty height and spacing between the two general switches.
  private var launchFeedbackRow: NSGridRow?

  /// Entire reset-notification feedback row, shown only while checking or requiring system permission.
  private var notificationFeedbackRow: NSGridRow?

  /// Entire expiry-notification feedback row, collapsed after system authorization is confirmed.
  private var creditNotificationFeedbackRow: NSGridRow?

  /// Overall default-on expiry preference, retained independently of system notification permission.
  private let creditExpirySwitch = NSSwitch()

  /// Independent first reminder switch, initially enabled with a twelve-hour lead time.
  private let firstCreditReminderSwitch = NSSwitch()

  /// Independent second reminder switch, initially enabled with a one-hour lead time.
  private let secondCreditReminderSwitch = NSSwitch()

  /// Integer-only hour field for the first reminder, saved on Return or when focus leaves it.
  private let firstCreditReminderField = NSTextField()

  /// Integer-only hour field for the second reminder, independent of the first reminder's value.
  private let secondCreditReminderField = NSTextField()

  /// First reminder's bounded hour stepper, incrementing exactly one hour per click.
  private let firstCreditReminderStepper = NSStepper()

  /// Second reminder's bounded hour stepper, incrementing exactly one hour per click.
  private let secondCreditReminderStepper = NSStepper()

  /// Permission feedback for expiry alerts without changing the default-on feature preference.
  private let creditNotificationStatusLabel = NSTextField(labelWithString: "")

  /// System settings entry shown when macOS has blocked expiry notifications.
  private let openCreditNotificationSettingsButton = NSButton(
    title: "打开系统设置", target: nil, action: nil
  )

  /// Scrolls tall settings on smaller screens while keeping every native control reachable.
  private let settingsScrollView = NSScrollView()

  /// Auto-sized document containing all settings sections and their asynchronous status rows.
  private let settingsContentView = SettingsContentView()

  /// Complete content stack used to measure the preferred height without expanding beyond the screen.
  private var settingsStack: NSStackView?

  /// Explicit automatic-greeting opt-in, independent of system notification permission.
  private let greetingSwitch = NSSwitch()

  /// Explains that greetings consume subscription usage without opening or retaining desktop chats.
  private let greetingHintLabel = NSTextField(
    wrappingLabelWithString: "独立后台执行，产生少量额度用量；无需打开聊天。")

  /// Delivery feedback showing accepted, deferred, failed or uncertain submissions.
  private let greetingStatusLabel = NSTextField(wrappingLabelWithString: "")

  /// Explicit user action that sends one greeting without enabling the automatic switch.
  private let testGreetingButton = NSButton(title: "测试发送你好", target: nil, action: nil)

  /// Opens the complete local execution log for inspecting failures and ambiguous requests.
  private let greetingLogButton = NSButton(title: "查看执行日志", target: nil, action: nil)

  /// Acknowledges an inspected uncertain result without automatically submitting it again.
  private let reviewGreetingButton = NSButton(title: "跳过本次，继续后续重置", target: nil, action: nil)

  /// Collapses the complete acknowledgement row when unused, including its otherwise stretchable spacer.
  private lazy var reviewGreetingRow = trailingControls([reviewGreetingButton])

  /// Command that opens the app-specific macOS notification settings pane.
  private let openNotificationSettingsButton = NSButton(
    title: "打开系统设置",
    target: nil,
    action: nil
  )

  /// Three-option selector for the menu-bar percentage font size.
  private let fontSizePopup = NSPopUpButton()

  /// Independently selects percentage or pie for the five-hour quota's primary menu-bar row.
  private let fiveHourStylePopup = NSPopUpButton()

  /// Independently selects percentage or pie for the seven-day quota's primary menu-bar row.
  private let sevenDayStylePopup = NSPopUpButton()

  /// Switch controlling quota-driven colors for menu-bar text and the pie chart.
  private let menuBarColorSwitch = NSSwitch()

  /// Selects countdown or the next reset time for both menu-bar quota columns, saving immediately.
  private let menuBarTimePopup = NSPopUpButton()

  /// Numeric field for lightweight HTTPS quota refresh seconds.
  private let quotaIntervalField = NSTextField()

  /// Stepper paired with the quota refresh field.
  private let quotaIntervalStepper = NSStepper()

  /// Numeric field for low-frequency App Server refresh minutes.
  private let creditsIntervalField = NSTextField()

  /// Stepper paired with the reset-credit refresh field.
  private let creditsIntervalStepper = NSStepper()

  /// Transient error line used when a system setting cannot be applied.
  private let errorLabel = NSTextField(labelWithString: "")

  /// Creates a settings controller bound to the long-lived application store.
  init(store: CodexQuotaStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }

  /// Prevents construction from archived interface files because the UI is programmatic.
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Builds native settings sections with immediate persistence and scrolling on smaller screens.
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 730))

    launchSwitch.target = self
    launchSwitch.action = #selector(launchSwitchChanged)

    launchStatusLabel.font = .systemFont(ofSize: 11)
    launchStatusLabel.textColor = .secondaryLabelColor
    launchStatusLabel.lineBreakMode = .byTruncatingTail

    openSystemSettingsButton.target = self
    openSystemSettingsButton.action = #selector(openSystemSettingsClicked)
    openSystemSettingsButton.bezelStyle = .rounded
    openSystemSettingsButton.controlSize = .small
    openSystemSettingsButton.isHidden = true

    notificationSwitch.target = self
    notificationSwitch.action = #selector(notificationSwitchChanged)

    creditExpirySwitch.target = self
    creditExpirySwitch.action = #selector(creditExpirySwitchChanged)
    for (toggle, field, stepper, label) in [
      (firstCreditReminderSwitch, firstCreditReminderField, firstCreditReminderStepper, "第一次提醒"),
      (secondCreditReminderSwitch, secondCreditReminderField, secondCreditReminderStepper, "第二次提醒"),
    ] {
      toggle.target = self
      toggle.action = #selector(creditReminderSwitchChanged(_:))
      toggle.setAccessibilityLabel(label)
      configureNumberField(
        field,
        minimum: 1,
        maximum: ResetCreditNotificationCoordinator.maximumReminderHours,
        action: #selector(creditReminderHoursCommitted(_:))
      )
      field.setAccessibilityLabel("\(label)提前小时数")
      configureStepper(
        stepper,
        minimum: 1,
        maximum: Double(ResetCreditNotificationCoordinator.maximumReminderHours),
        increment: 1,
        action: #selector(creditReminderStepperChanged(_:))
      )
      stepper.setAccessibilityLabel("\(label)提前小时数")
    }
    creditNotificationStatusLabel.font = .systemFont(ofSize: 11)
    creditNotificationStatusLabel.textColor = .secondaryLabelColor
    openCreditNotificationSettingsButton.target = self
    openCreditNotificationSettingsButton.action = #selector(openNotificationSettingsClicked)
    openCreditNotificationSettingsButton.bezelStyle = .rounded
    openCreditNotificationSettingsButton.controlSize = .small
    openCreditNotificationSettingsButton.isHidden = true

    greetingSwitch.target = self
    greetingSwitch.action = #selector(greetingSwitchChanged)
    greetingHintLabel.font = .systemFont(ofSize: 11)
    greetingHintLabel.textColor = .secondaryLabelColor
    greetingStatusLabel.font = .systemFont(ofSize: 11)
    greetingStatusLabel.textColor = .secondaryLabelColor
    greetingStatusLabel.maximumNumberOfLines = 6
    for button in [testGreetingButton, greetingLogButton, reviewGreetingButton] {
      button.target = self
      button.bezelStyle = .rounded
      button.controlSize = .small
    }
    testGreetingButton.action = #selector(testGreetingClicked)
    greetingLogButton.action = #selector(greetingLogClicked)
    reviewGreetingButton.action = #selector(reviewGreetingClicked)

    notificationStatusLabel.font = .systemFont(ofSize: 11)
    notificationStatusLabel.textColor = .secondaryLabelColor
    notificationStatusLabel.lineBreakMode = .byTruncatingTail

    openNotificationSettingsButton.target = self
    openNotificationSettingsButton.action = #selector(openNotificationSettingsClicked)
    openNotificationSettingsButton.bezelStyle = .rounded
    openNotificationSettingsButton.controlSize = .small
    openNotificationSettingsButton.isHidden = true

    for option in [
      ("小（13）", 13),
      ("标准（14）", 14),
      ("大（15）", 15),
    ] {
      fontSizePopup.addItem(withTitle: option.0)
      fontSizePopup.lastItem?.representedObject = option.1
    }
    fontSizePopup.target = self
    fontSizePopup.action = #selector(fontSizeChanged)

    configureQuotaStylePopup(fiveHourStylePopup, label: "5 小时额度样式")
    configureQuotaStylePopup(sevenDayStylePopup, label: "7 天额度样式")

    menuBarColorSwitch.target = self
    menuBarColorSwitch.action = #selector(menuBarColorSwitchChanged)

    for mode in MenuBarTimeDisplayMode.allCases {
      menuBarTimePopup.addItem(withTitle: mode.displayName)
      menuBarTimePopup.lastItem?.representedObject = mode.rawValue
    }
    menuBarTimePopup.target = self
    menuBarTimePopup.action = #selector(menuBarTimeModeChanged)
    menuBarTimePopup.setAccessibilityLabel("菜单栏时间")

    configureNumberField(
      quotaIntervalField,
      minimum: 10,
      maximum: 86_400,
      action: #selector(quotaIntervalCommitted)
    )
    configureStepper(
      quotaIntervalStepper,
      minimum: 10,
      maximum: 86_400,
      increment: 10,
      action: #selector(quotaStepperChanged)
    )
    configureNumberField(
      creditsIntervalField,
      minimum: 1,
      maximum: 60,
      action: #selector(creditsIntervalCommitted)
    )
    configureStepper(
      creditsIntervalStepper,
      minimum: 1,
      maximum: 60,
      increment: 1,
      action: #selector(creditsStepperChanged)
    )

    errorLabel.font = .systemFont(ofSize: 11)
    errorLabel.textColor = .systemRed
    errorLabel.maximumNumberOfLines = 2
    errorLabel.isHidden = true

    let generalGrid = settingsGrid(
      rows: [
        [settingLabel("开机时启动"), trailingControls([launchSwitch])],
        [
          launchStatusLabel,
          trailingControls([openSystemSettingsButton]),
        ],
        [
          settingLabel("额度重置通知"),
          trailingControls([notificationSwitch]),
        ],
        [
          notificationStatusLabel,
          trailingControls([openNotificationSettingsButton]),
        ],
      ]
    )
    launchFeedbackRow = generalGrid.row(at: 1)
    notificationFeedbackRow = generalGrid.row(at: 3)
    let greetingGrid = settingsGrid(rows: [
      [settingLabel("重置后发送“你好”"), trailingControls([greetingSwitch])]
    ])
    let creditReminderGrid = settingsGrid(rows: [
      [settingLabel("到期通知"), trailingControls([creditExpirySwitch])],
      [
        settingLabel("第一次提醒"),
        creditReminderControls(
          toggle: firstCreditReminderSwitch,
          field: firstCreditReminderField,
          stepper: firstCreditReminderStepper
        ),
      ],
      [
        settingLabel("第二次提醒"),
        creditReminderControls(
          toggle: secondCreditReminderSwitch,
          field: secondCreditReminderField,
          stepper: secondCreditReminderStepper
        ),
      ],
      [creditNotificationStatusLabel, trailingControls([openCreditNotificationSettingsButton])],
    ])
    creditNotificationFeedbackRow = creditReminderGrid.row(at: 3)
    let greetingSection = NSStackView(views: [
      greetingGrid,
      greetingHintLabel,
      trailingControls([greetingLogButton, testGreetingButton]),
      greetingStatusLabel,
      reviewGreetingRow,
    ])
    greetingSection.orientation = .vertical
    greetingSection.alignment = .leading
    greetingSection.spacing = 9
    greetingSection.setContentHuggingPriority(.required, for: .vertical)

    let appearanceGrid = settingsGrid(
      rows: [
        [settingLabel("5 小时额度样式"), trailingControls([fiveHourStylePopup])],
        [settingLabel("7 天额度样式"), trailingControls([sevenDayStylePopup])],
        [settingLabel("百分比字号"), trailingControls([fontSizePopup])],
        [settingLabel("菜单栏时间"), trailingControls([menuBarTimePopup])],
        [
          settingLabel("菜单栏额度颜色"),
          trailingControls([menuBarColorSwitch]),
        ],
      ]
    )
    let refreshGrid = settingsGrid(
      rows: [
        [
          settingLabel("额度刷新"),
          numericControls(
            field: quotaIntervalField,
            stepper: quotaIntervalStepper,
            unit: "秒"
          ),
        ],
        [
          settingLabel("重置卡刷新"),
          numericControls(
            field: creditsIntervalField,
            stepper: creditsIntervalStepper,
            unit: "分钟"
          ),
        ],
      ]
    )

    let stack = NSStackView(
      views: [
        sectionTitle("通用"),
        generalGrid,
        divider(),
        sectionTitle("重置卡到期提醒"),
        creditReminderGrid,
        divider(),
        sectionTitle("自动问候"),
        greetingSection,
        divider(),
        sectionTitle("显示"),
        appearanceGrid,
        divider(),
        sectionTitle("数据刷新"),
        refreshGrid,
        errorLabel,
      ]
    )
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.setContentHuggingPriority(.required, for: .vertical)
    stack.translatesAutoresizingMaskIntoConstraints = false
    settingsStack = stack
    settingsScrollView.translatesAutoresizingMaskIntoConstraints = false
    settingsScrollView.hasVerticalScroller = true
    settingsScrollView.autohidesScrollers = true
    settingsScrollView.drawsBackground = false
    settingsContentView.translatesAutoresizingMaskIntoConstraints = false
    settingsScrollView.documentView = settingsContentView
    settingsContentView.addSubview(stack)
    view.addSubview(settingsScrollView)

    NSLayoutConstraint.activate([
      settingsScrollView.topAnchor.constraint(equalTo: view.topAnchor),
      settingsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      settingsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      settingsScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      settingsContentView.widthAnchor.constraint(equalTo: settingsScrollView.contentView.widthAnchor),
      stack.topAnchor.constraint(equalTo: settingsContentView.topAnchor, constant: 22),
      stack.leadingAnchor.constraint(equalTo: settingsContentView.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: settingsContentView.trailingAnchor, constant: -24),
      stack.bottomAnchor.constraint(equalTo: settingsContentView.bottomAnchor, constant: -22),
      generalGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      creditReminderGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      greetingSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
      greetingGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      greetingHintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      greetingStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      appearanceGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      refreshGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      quotaIntervalField.widthAnchor.constraint(equalToConstant: 76),
      creditsIntervalField.widthAnchor.constraint(equalToConstant: 76),
      firstCreditReminderField.widthAnchor.constraint(equalToConstant: 54),
      secondCreditReminderField.widthAnchor.constraint(equalToConstant: 54),
      fontSizePopup.widthAnchor.constraint(equalToConstant: 126),
      fiveHourStylePopup.widthAnchor.constraint(equalToConstant: 126),
      sevenDayStylePopup.widthAnchor.constraint(equalToConstant: 126),
      menuBarTimePopup.widthAnchor.constraint(equalToConstant: 150),
    ])

    store.onGreetingChange = { [weak self] in
      guard let self, self.isViewLoaded else { return }
      self.renderGreeting()
    }
    store.onNotificationChange = { [weak self] in
      guard let self, self.isViewLoaded else { return }
      self.renderNotifications()
    }
    render()
  }

  /// Refreshes login-item state whenever the retained window becomes visible.
  override func viewWillAppear() {
    super.viewWillAppear()
    render()
    store.refreshResetNotificationAuthorizationStatus { [weak self] in
      self?.render()
    }
  }

  /// Commits the edited numeric setting when focus leaves either interval field.
  func controlTextDidEndEditing(_ obj: Notification) {
    guard let field = obj.object as? NSTextField else {
      return
    }
    if field === quotaIntervalField {
      commitQuotaInterval()
    } else if field === creditsIntervalField {
      commitCreditsInterval()
    } else if field === firstCreditReminderField || field === secondCreditReminderField {
      commitCreditReminderHours(field)
    }
  }

  /// Synchronizes every control from persisted values and current macOS service state.
  private func render() {
    renderGreeting()
    quotaIntervalField.integerValue = store.refreshIntervalSeconds
    quotaIntervalStepper.integerValue = store.refreshIntervalSeconds
    creditsIntervalField.integerValue = store.creditsRefreshIntervalMinutes
    creditsIntervalStepper.integerValue = store.creditsRefreshIntervalMinutes
    for (slot, field, stepper) in [
      (ResetCreditReminderSlot.first, firstCreditReminderField, firstCreditReminderStepper),
      (ResetCreditReminderSlot.second, secondCreditReminderField, secondCreditReminderStepper),
    ] {
      let settings = store.creditExpiryReminderSettings(for: slot)
      field.integerValue = settings.hours
      stepper.integerValue = settings.hours
    }
    menuBarColorSwitch.state = store.menuBarDynamicColorsEnabled ? .on : .off

    for (popup, kind) in [
      (fiveHourStylePopup, QuotaKind.fiveHour),
      (sevenDayStylePopup, QuotaKind.sevenDay),
    ] {
      if let item = popup.itemArray.first(where: {
        ($0.representedObject as? String) == store.menuBarQuotaStyle(for: kind).rawValue
      }) {
        popup.select(item)
      }
    }

    if let item = fontSizePopup.itemArray.first(where: {
      ($0.representedObject as? Int) == store.menuBarFontSize
    }) {
      fontSizePopup.select(item)
    }

    if let item = menuBarTimePopup.itemArray.first(where: {
      ($0.representedObject as? String) == store.menuBarTimeDisplayMode.rawValue
    }) {
      menuBarTimePopup.select(item)
    }

    launchSwitch.isEnabled = true
    openSystemSettingsButton.isHidden = true
    switch launchAtLogin.state {
    case .enabled:
      launchSwitch.state = .on
      launchStatusLabel.stringValue = ""
    case .disabled:
      launchSwitch.state = .off
      launchStatusLabel.stringValue = ""
    case .requiresApproval:
      launchSwitch.state = .on
      launchStatusLabel.stringValue = "等待系统批准"
      openSystemSettingsButton.isHidden = false
    case .unavailable:
      launchSwitch.state = .off
      launchSwitch.isEnabled = false
      launchStatusLabel.stringValue = "当前不可用"
    }
    launchFeedbackRow?.isHidden =
      launchStatusLabel.stringValue.isEmpty && openSystemSettingsButton.isHidden

    renderNotifications()
    resizeToFitContents()
  }

  /// Updates notification switches and permission feedback without overwriting edited hour fields.
  /// Expiry opt-in stays enabled when permission is denied so granting permission resumes reminders.
  private func renderNotifications() {
    notificationSwitch.isEnabled = true
    notificationSwitch.state = store.resetNotificationsEnabled ? .on : .off
    notificationStatusLabel.stringValue = ""
    openNotificationSettingsButton.isHidden = true
    switch store.resetNotificationAuthorizationState {
    case .unknown:
      notificationSwitch.state = .off
      notificationSwitch.isEnabled = false
      notificationStatusLabel.stringValue = "正在检查系统通知权限"
    case .notDetermined:
      notificationSwitch.state = .off
      notificationStatusLabel.stringValue = "尚未授权，请开启通知"
    case .denied:
      notificationSwitch.state = .off
      notificationStatusLabel.stringValue = "系统通知已关闭"
      openNotificationSettingsButton.isHidden = false
    case .authorized:
      break
    }
    notificationFeedbackRow?.isHidden =
      notificationStatusLabel.stringValue.isEmpty && openNotificationSettingsButton.isHidden
    creditExpirySwitch.state = store.creditExpiryNotificationsEnabled ? .on : .off
    creditNotificationStatusLabel.stringValue = ""
    openCreditNotificationSettingsButton.isHidden = true
    switch store.resetNotificationAuthorizationState {
    case .unknown:
      creditNotificationStatusLabel.stringValue = "正在检查系统通知权限"
    case .notDetermined:
      creditNotificationStatusLabel.stringValue = "尚未授权系统通知"
    case .denied:
      creditNotificationStatusLabel.stringValue = "系统通知已关闭"
      openCreditNotificationSettingsButton.isHidden = false
    case .authorized:
      break
    }
    creditNotificationFeedbackRow?.isHidden =
      creditNotificationStatusLabel.stringValue.isEmpty && openCreditNotificationSettingsButton.isHidden
    for (slot, toggle, field, stepper) in [
      (ResetCreditReminderSlot.first, firstCreditReminderSwitch, firstCreditReminderField,
        firstCreditReminderStepper),
      (ResetCreditReminderSlot.second, secondCreditReminderSwitch, secondCreditReminderField,
        secondCreditReminderStepper),
    ] {
      let settings = store.creditExpiryReminderSettings(for: slot)
      toggle.state = settings.isEnabled ? .on : .off
      toggle.isEnabled = store.creditExpiryNotificationsEnabled
      field.isEnabled = store.creditExpiryNotificationsEnabled && settings.isEnabled
      stepper.isEnabled = field.isEnabled
    }
    resizeToFitContents()
  }

  /// Renders background completion and usage without requiring a destination chat or navigation.
  private func renderGreeting() {
    greetingSwitch.state = store.resetGreetingsEnabled ? .on : .off
    greetingSwitch.isEnabled = store.resetGreetingsAvailable
    greetingStatusLabel.stringValue = store.resetGreetingStatus
    testGreetingButton.isEnabled = store.canSendResetGreetingTest
    reviewGreetingButton.isHidden = !store.resetGreetingNeedsReview
    reviewGreetingRow.isHidden = !store.resetGreetingNeedsReview
    reviewGreetingButton.isEnabled = !store.isSendingGreeting
    resizeToFitContents()
  }

  /// Fits the window to visible controls while preserving its top edge as asynchronous status changes.
  /// Required vertical hugging keeps unused rows from stretching into the former fixed-height space.
  func resizeToFitContents() {
    guard isViewLoaded, let window = view.window else { return }
    view.layoutSubtreeIfNeeded()
    let preferredHeight = ceil((settingsStack?.fittingSize.height ?? 686) + 44)
    let availableHeight = max(
      320, (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
    ) - 80
    let contentSize = NSSize(width: 460, height: min(preferredHeight, availableHeight))
    let fittedFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
    var frame = window.frame
    guard abs(frame.height - fittedFrame.height) > 0.5 else { return }
    frame.origin.y += frame.height - fittedFrame.height
    frame.size = fittedFrame.size
    window.setFrame(frame, display: window.isVisible)
  }

  /// Presents actionable greeting errors while retaining the shared settings window and its focus.
  private func applyGreetingChange(_ change: () throws -> Void) {
    do {
      try change()
      errorLabel.stringValue = ""
      errorLabel.isHidden = true
    } catch {
      errorLabel.stringValue = error.localizedDescription
      errorLabel.isHidden = false
    }
    renderGreeting()
  }

  /// Applies the opt-in or stops active local execution when the user disables the switch.
  @objc private func greetingSwitchChanged() {
    let enabled = greetingSwitch.state == .on
    applyGreetingChange { try store.setResetGreetingsEnabled(enabled) }
  }

  /// Submits only after the user explicitly clicks the test button, even with automation disabled.
  @objc private func testGreetingClicked() {
    applyGreetingChange { try store.sendResetGreetingTest() }
  }

  /// Opens local diagnostics in the user's default file viewer without activating a Codex chat.
  @objc private func greetingLogClicked() {
    let fileManager = FileManager.default
    let directory = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/CodexQuota", isDirectory: true)
    let log = directory.appendingPathComponent("rpc.log")
    NSWorkspace.shared.open(fileManager.fileExists(atPath: log.path) ? log : directory)
  }

  /// Resumes future detection after the user has inspected a possibly submitted greeting.
  @objc private func reviewGreetingClicked() {
    applyGreetingChange { try store.acknowledgeResetGreetingReview() }
  }

  /// Populates one independent style selector with stable raw values and an accessible window label.
  /// Both selectors share the same action; sender identity determines which quota preference is saved.
  private func configureQuotaStylePopup(_ popup: NSPopUpButton, label: String) {
    for style in MenuBarQuotaDisplayStyle.allCases {
      popup.addItem(withTitle: style.displayName)
      popup.lastItem?.representedObject = style.rawValue
    }
    popup.target = self
    popup.action = #selector(quotaStyleChanged(_:))
    popup.setAccessibilityLabel(label)
  }

  /// Configures an integer-only text field with bounds and Return-key action.
  private func configureNumberField(
    _ field: NSTextField,
    minimum: Int,
    maximum: Int,
    action: Selector
  ) {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.minimum = NSNumber(value: minimum)
    formatter.maximum = NSNumber(value: maximum)
    formatter.allowsFloats = false
    field.formatter = formatter
    field.alignment = .right
    field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    field.delegate = self
    field.target = self
    field.action = action
  }

  /// Configures one bounded numeric stepper and its immediate-save action.
  private func configureStepper(
    _ stepper: NSStepper,
    minimum: Double,
    maximum: Double,
    increment: Double,
    action: Selector
  ) {
    stepper.minValue = minimum
    stepper.maxValue = maximum
    stepper.increment = increment
    stepper.valueWraps = false
    stepper.target = self
    stepper.action = action
  }

  /// Creates a compact section title matching native preference density.
  private func sectionTitle(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = .labelColor
    return label
  }

  /// Creates a left-column setting label with restrained secondary emphasis.
  private func settingLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    return label
  }

  /// Creates a right-aligned horizontal control group for one settings row.
  private func trailingControls(_ controls: [NSView]) -> NSStackView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [spacer] + controls)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    return stack
  }

  /// Creates a right-aligned field, stepper, and unit group for numeric settings.
  private func numericControls(
    field: NSTextField,
    stepper: NSStepper,
    unit: String
  ) -> NSStackView {
    let unitLabel = NSTextField(labelWithString: unit)
    unitLabel.font = .systemFont(ofSize: 12)
    unitLabel.textColor = .secondaryLabelColor
    return trailingControls([field, stepper, unitLabel])
  }

  /// Groups one independent reminder switch with an integer-hour field and one-hour stepper.
  private func creditReminderControls(
    toggle: NSSwitch,
    field: NSTextField,
    stepper: NSStepper
  ) -> NSStackView {
    let prefix = settingLabel("提前")
    let unit = settingLabel("小时")
    return trailingControls([toggle, prefix, field, stepper, unit])
  }

  /// Creates a two-column settings grid with stable row and column spacing.
  private func settingsGrid(rows: [[NSView]]) -> NSGridView {
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 12
    grid.columnSpacing = 20
    grid.column(at: 0).xPlacement = .leading
    grid.column(at: 1).xPlacement = .fill
    return grid
  }

  /// Creates a full-width divider between settings sections.
  private func divider() -> NSBox {
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
    divider.widthAnchor.constraint(equalToConstant: 412).isActive = true
    return divider
  }

  /// Persists the quota field through the store's request-protection bounds.
  private func commitQuotaInterval() {
    store.setRefreshInterval(seconds: quotaIntervalField.integerValue)
    render()
  }

  /// Persists the reset-credit field through the store's process-protection bounds.
  private func commitCreditsInterval() {
    store.setCreditsRefreshInterval(minutes: creditsIntervalField.integerValue)
    render()
  }

  /// Commits only the edited reminder value, preserving the other field's focus and saved history.
  private func commitCreditReminderHours(_ field: NSTextField) {
    let slot: ResetCreditReminderSlot = field === firstCreditReminderField ? .first : .second
    store.setCreditExpiryReminderHours(field.integerValue, for: slot)
    let hours = store.creditExpiryReminderSettings(for: slot).hours
    field.integerValue = hours
    let stepper = slot == .first ? firstCreditReminderStepper : secondCreditReminderStepper
    stepper.integerValue = hours
  }

  /// Saves the master preference while keeping system authorization feedback separate from opt-in.
  @objc private func creditExpirySwitchChanged() {
    let enabled = creditExpirySwitch.state == .on
    store.setCreditExpiryNotificationsEnabled(enabled) { [weak self] _ in
      self?.renderNotifications()
    }
  }

  /// Saves an independent reminder switch without sending or forgetting a prior accepted alert.
  @objc private func creditReminderSwitchChanged(_ sender: NSSwitch) {
    let slot: ResetCreditReminderSlot = sender === firstCreditReminderSwitch ? .first : .second
    store.setCreditExpiryReminderEnabled(sender.state == .on, for: slot)
  }

  /// Handles Return in either integer-only expiry reminder hour field.
  @objc private func creditReminderHoursCommitted(_ sender: NSTextField) {
    commitCreditReminderHours(sender)
  }

  /// Applies an exact one-hour stepper change to the associated persisted reminder preference.
  @objc private func creditReminderStepperChanged(_ sender: NSStepper) {
    let field = sender === firstCreditReminderStepper
      ? firstCreditReminderField : secondCreditReminderField
    field.integerValue = sender.integerValue
    commitCreditReminderHours(field)
  }

  /// Applies the native login-item switch and surfaces any registration failure.
  @objc private func launchSwitchChanged() {
    do {
      try launchAtLogin.setEnabled(launchSwitch.state == .on)
      errorLabel.stringValue = ""
      errorLabel.isHidden = true
    } catch {
      errorLabel.stringValue = "无法更新开机启动设置"
      errorLabel.isHidden = false
    }
    render()
  }

  /// Opens the macOS Login Items page for an approval-required registration.
  @objc private func openSystemSettingsClicked() {
    launchAtLogin.openSystemSettings()
  }

  /// Applies the explicit notification opt-in and reflects any denied system permission.
  @objc private func notificationSwitchChanged() {
    let requestedValue = notificationSwitch.state == .on
    notificationSwitch.isEnabled = false
    store.setResetNotificationsEnabled(requestedValue) { [weak self] effectiveValue in
      guard let self else {
        return
      }
      if requestedValue && !effectiveValue
        && self.store.resetNotificationAuthorizationState != .denied
      {
        self.errorLabel.stringValue = "无法开启额度重置通知"
        self.errorLabel.isHidden = false
      } else {
        self.errorLabel.stringValue = ""
        self.errorLabel.isHidden = true
      }
      self.render()
    }
  }

  /// Opens macOS notification settings so denied permission can be restored.
  @objc private func openNotificationSettingsClicked() {
    store.openResetNotificationSystemSettings()
  }

  /// Applies the selected menu-bar font size immediately.
  @objc private func fontSizeChanged() {
    guard let size = fontSizePopup.selectedItem?.representedObject as? Int else {
      return
    }
    store.setMenuBarFontSize(size)
  }

  /// Persists the sending selector's style immediately while preserving the other quota's choice.
  @objc private func quotaStyleChanged(_ sender: NSPopUpButton) {
    guard let value = sender.selectedItem?.representedObject as? String,
      let style = MenuBarQuotaDisplayStyle(rawValue: value)
    else {
      return
    }
    let kind: QuotaKind
    if sender === fiveHourStylePopup {
      kind = .fiveHour
    } else if sender === sevenDayStylePopup {
      kind = .sevenDay
    } else {
      return
    }
    store.setMenuBarQuotaStyle(style, for: kind)
  }

  /// Applies the menu-bar quota color preference immediately without restarting the app.
  @objc private func menuBarColorSwitchChanged() {
    store.setMenuBarDynamicColorsEnabled(menuBarColorSwitch.state == .on)
  }

  /// Applies and persists the selected secondary-row time format for both quota columns immediately.
  @objc private func menuBarTimeModeChanged() {
    guard let value = menuBarTimePopup.selectedItem?.representedObject as? String,
      let mode = MenuBarTimeDisplayMode(rawValue: value)
    else {
      return
    }
    store.setMenuBarTimeDisplayMode(mode)
  }

  /// Handles Return in the quota interval field.
  @objc private func quotaIntervalCommitted() {
    commitQuotaInterval()
  }

  /// Handles Return in the reset-credit interval field.
  @objc private func creditsIntervalCommitted() {
    commitCreditsInterval()
  }

  /// Synchronizes and persists a quota stepper change.
  @objc private func quotaStepperChanged() {
    quotaIntervalField.integerValue = quotaIntervalStepper.integerValue
    commitQuotaInterval()
  }

  /// Synchronizes and persists a reset-credit stepper change.
  @objc private func creditsStepperChanged() {
    creditsIntervalField.integerValue = creditsIntervalStepper.integerValue
    commitCreditsInterval()
  }
}

/// Top-origin settings document that naturally opens at the first section inside a scroll view.
private final class SettingsContentView: NSView {
  /// Uses a top-left origin so initial scrolling and expanding status rows preserve reading order.
  override var isFlipped: Bool { true }
}
