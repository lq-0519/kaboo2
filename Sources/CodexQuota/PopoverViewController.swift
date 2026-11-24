import AppKit

/// Renders the complete menu-bar popover and owns its visibility-scoped countdown timer.
final class PopoverViewController: NSViewController {
  /// Shared store supplying live snapshots and accepting refresh settings.
  private let store: CodexQuotaStore

  /// 在弹窗首屏展示今天和最近七个本地自然日观察到的七天额度消耗。
  private let dailyQuotaUsageView = DailyQuotaUsageView()

  /// 容纳整个弹窗的滚动视图，重新打开时定位到顶部的趋势图。
  private let scrollView = NSScrollView()

  /// Five-hour quota view placed first to match the status-item order.
  private let fiveHourView = QuotaRowView()

  /// 成功查询但未返回五小时额度时，替代额度行展示套餐名称和缺失说明；加载中仍使用原占位状态。
  private let planSummaryView = NSStackView()

  /// 展示与当前额度快照匹配的套餐名称；未知套餐只显示通用标题，不将缺少五小时额度等同于 Pro。
  private let planLabel = NSTextField(labelWithString: "当前套餐")

  /// Seven-day quota view placed second to match the status-item order.
  private let sevenDayView = QuotaRowView()

  /// Error text for the quota path, collapsed when the latest request succeeded.
  private let quotaErrorLabel = NSTextField(labelWithString: "")

  /// Section count that uses the authoritative `availableCount`.
  private let creditsCountLabel = NSTextField(labelWithString: "--")

  /// Dynamic stack containing individual reset-credit cards or one empty state.
  private let creditsStack = NSStackView()

  /// Full vertical content stack used to calculate the popover's exact required height.
  private let contentStack = NSStackView()

  /// Active credit cards retained for local one-second countdown ticks.
  private var creditRows: [ResetCreditRowView] = []

  /// Footer freshness summary for both independent data paths.
  private let freshnessLabel = NSTextField(labelWithString: "")

  /// Header activity indicator reflecting either refresh path.
  private let progressIndicator = NSProgressIndicator()

  /// Icon-only refresh command that triggers both independent queries.
  private lazy var refreshButton = makeIconButton(
    symbol: "arrow.clockwise",
    tooltip: "立即刷新",
    action: #selector(refreshClicked)
  )

  /// Icon-only settings command that opens the dedicated preferences window.
  private lazy var settingsButton = makeIconButton(
    symbol: "gearshape",
    tooltip: "设置",
    action: #selector(settingsClicked)
  )

  /// Icon-only quit command kept away from the main data scanning path.
  private lazy var quitButton = makeIconButton(
    symbol: "power",
    tooltip: "退出 Codex Quota",
    action: #selector(quitClicked)
  )

  /// Timer that updates relative labels only while the popover is open.
  private var countdownTimer: Timer?

  /// Tracks presentation from will-appear through will-disappear so background store updates
  /// never rebuild hidden card rows, update hidden controls, or measure the hidden layout.
  /// The shared store retains fresh data; prepareForPresentation reads it before each opening.
  private var isPopoverVisible = false

  /// Callback supplied by the app delegate to open the retained settings window.
  var onOpenSettings: (() -> Void)?

  /// Creates a popover bound to one long-lived application store.
  init(store: CodexQuotaStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = NSSize(width: 380, height: 560)
  }

  /// Prevents construction from archived interface files because the UI is programmatic.
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Builds the scrollable, full-width data surface with no nested page cards.
  override func loadView() {
    view = PopoverTintView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.hasHorizontalScroller = false
    view.addSubview(scrollView)

    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = document

    let titleLabel = NSTextField(labelWithString: "Codex 用量")
    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = QuotaPopoverColors.primaryText

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.isDisplayedWhenStopped = false

    let headerSpacer = NSView()
    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(
      views: [
        titleLabel,
        headerSpacer,
        progressIndicator,
        refreshButton,
        settingsButton,
        quitButton,
      ]
    )
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8

    quotaErrorLabel.font = .systemFont(ofSize: 11)
    quotaErrorLabel.textColor = .systemRed
    quotaErrorLabel.maximumNumberOfLines = 2
    quotaErrorLabel.lineBreakMode = .byWordWrapping
    quotaErrorLabel.isHidden = true

    planLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    planLabel.textColor = QuotaPopoverColors.primaryText
    let noFiveHourLabel = NSTextField(labelWithString: "无 5 小时额度")
    noFiveHourLabel.font = .systemFont(ofSize: 12)
    noFiveHourLabel.textColor = QuotaPopoverColors.secondaryText
    planSummaryView.orientation = .vertical
    planSummaryView.alignment = .leading
    planSummaryView.spacing = 6
    planSummaryView.addArrangedSubview(planLabel)
    planSummaryView.addArrangedSubview(noFiveHourLabel)
    planSummaryView.isHidden = true

    let creditsTitle = NSTextField(labelWithString: "重置卡")
    creditsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
    creditsTitle.textColor = QuotaPopoverColors.primaryText
    creditsCountLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    creditsCountLabel.textColor = QuotaPopoverColors.secondaryText
    creditsCountLabel.alignment = .right

    let creditsSpacer = NSView()
    creditsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let creditsHeader = NSStackView(
      views: [creditsTitle, creditsSpacer, creditsCountLabel]
    )
    creditsHeader.orientation = .horizontal
    creditsHeader.alignment = .centerY
    creditsHeader.spacing = 8

    creditsStack.orientation = .vertical
    creditsStack.alignment = .leading
    creditsStack.spacing = 8

    freshnessLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    freshnessLabel.textColor = QuotaPopoverColors.secondaryText
    freshnessLabel.lineBreakMode = .byTruncatingTail

    let headerDivider = divider()
    let dailyUsageDivider = divider()
    let fiveHourDivider = divider()
    let quotaDivider = divider()
    let footerDivider = divider()
    for arrangedView in [
      header,
      headerDivider,
      dailyQuotaUsageView,
      dailyUsageDivider,
      planSummaryView,
      fiveHourView,
      fiveHourDivider,
      sevenDayView,
      quotaErrorLabel,
      quotaDivider,
      creditsHeader,
      creditsStack,
      footerDivider,
      freshnessLabel,
    ] {
      contentStack.addArrangedSubview(arrangedView)
    }
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 12
    contentStack.detachesHiddenViews = true
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(contentStack)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
      contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
      contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
      contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
      contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
      header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      dailyQuotaUsageView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      planSummaryView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      fiveHourView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      sevenDayView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      quotaErrorLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      creditsHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      creditsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      freshnessLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      headerDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      dailyUsageDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      fiveHourDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      quotaDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
      footerDivider.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
    ])
  }

  /// Enables live store rendering when AppKit begins presenting the prepared popover.
  /// Its initial content and size have already been synchronized before NSPopover.show.
  override func viewWillAppear() {
    super.viewWillAppear()
    isPopoverVisible = true
  }

  /// Starts the local countdown only after AppKit makes the popover visible.
  override func viewDidAppear() {
    super.viewDidAppear()
    store.refreshCreditsIfStale()
    startCountdownTimer()
  }

  /// Stops live rendering, countdown wakeups, and the activity animation as closing begins.
  /// Network refreshes continue in the shared store and are displayed on the next opening.
  override func viewWillDisappear() {
    isPopoverVisible = false
    countdownTimer?.invalidate()
    countdownTimer = nil
    progressIndicator.stopAnimation(nil)
    super.viewWillDisappear()
  }

  /// 打开前加载最新快照，按显示器可用高度预先确定弹窗尺寸，并将内容滚回顶部。
  func prepareForPresentation(maximumHeight: CGFloat) {
    _ = view
    store.refreshDailyQuotaUsageAccount()
    renderSnapshot(maximumHeight: maximumHeight)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  /// 仅在面板显示期间同步最新数据和可用高度，后台刷新时无需测量隐藏界面。
  func render(maximumHeight: CGFloat) {
    guard isPopoverVisible, isViewLoaded else {
      return
    }
    renderSnapshot(maximumHeight: maximumHeight)
  }

  /// 在面板可见更新或打开前准备时，同步额度、套餐说明、重置卡、刷新状态和内容高度。
  /// 仅在已有成功快照且缺少五小时窗口时显示套餐说明，避免将加载中或首次查询失败误判为无额度。
  private func renderSnapshot(maximumHeight: CGFloat) {
    dailyQuotaUsageView.update(days: store.recentDailyQuotaUsage())
    let snapshot = store.quotaSnapshot
    let showsPlanSummary = snapshot != nil && snapshot?.fiveHour == nil
    fiveHourView.isHidden = showsPlanSummary
    planSummaryView.isHidden = !showsPlanSummary
    planLabel.stringValue = snapshot?.planDisplayName.map { "当前套餐：\($0)" } ?? "当前套餐"

    sevenDayView.update(
      window: snapshot?.sevenDay,
      fallbackKind: .sevenDay
    )
    fiveHourView.update(
      window: snapshot?.fiveHour,
      fallbackKind: .fiveHour
    )

    quotaErrorLabel.stringValue = store.quotaError ?? ""
    quotaErrorLabel.isHidden = store.quotaError == nil
    refreshButton.isEnabled = !store.isRefreshing
    store.isRefreshing
      ? progressIndicator.startAnimation(nil) : progressIndicator.stopAnimation(nil)

    rebuildCredits()
    let quotaFreshness = DisplayFormatter.freshness(store.quotaSnapshot?.fetchedAt)
    let creditFreshness = DisplayFormatter.freshness(store.creditsSnapshot?.fetchedAt)
    freshnessLabel.stringValue = "额度 \(quotaFreshness) · 重置卡 \(creditFreshness)"
    updatePreferredContentSize(maximumHeight: maximumHeight)
  }

  /// Creates a symbol-only command button with an explicit accessibility description.
  private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
    let button = NSButton()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
    button.imagePosition = .imageOnly
    button.contentTintColor = QuotaPopoverColors.accentText
    button.bezelStyle = .texturedRounded
    button.isBordered = true
    button.controlSize = .small
    button.toolTip = tooltip
    button.target = self
    button.action = action
    return button
  }

  /// Creates a full-width semantic divider for major information groups.
  private func divider() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    box.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return box
  }

  /// Rebuilds the repeated credit cards after a low-frequency store update.
  private func rebuildCredits() {
    for view in creditsStack.arrangedSubviews {
      creditsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    creditRows.removeAll()

    guard let snapshot = store.creditsSnapshot else {
      creditsCountLabel.stringValue = "--"
      creditsStack.addArrangedSubview(
        mutedLabel(store.creditsError ?? "正在读取重置卡")
      )
      return
    }

    creditsCountLabel.stringValue = "\(snapshot.availableCount) 张"
    for credit in snapshot.items {
      let row = ResetCreditRowView(credit: credit)
      creditRows.append(row)
      creditsStack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: creditsStack.widthAnchor).isActive = true
    }

    if snapshot.items.isEmpty {
      creditsStack.addArrangedSubview(
        mutedLabel(snapshot.availableCount == 0 ? "暂无可用重置卡" : "重置卡明细未提供")
      )
    } else if snapshot.items.count < snapshot.availableCount {
      let omitted = snapshot.availableCount - snapshot.items.count
      creditsStack.addArrangedSubview(mutedLabel("另有 \(omitted) 张未提供明细"))
    }
    if store.creditsError != nil {
      creditsStack.addArrangedSubview(mutedLabel("更新失败 · 显示上次结果"))
    }
  }

  /// Creates one wrapping secondary label for empty, omitted, or stale states.
  private func mutedLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = QuotaPopoverColors.secondaryText
    return label
  }

  /// 按内容自然高度展开到显示器允许的上限，超出的内容由原有滚动视图承载。
  private func updatePreferredContentSize(maximumHeight: CGFloat) {
    view.layoutSubtreeIfNeeded()
    let verticalInsets: CGFloat = 32
    let requiredHeight = ceil(contentStack.fittingSize.height + verticalInsets)
    let boundedHeight = min(maximumHeight, max(260, requiredHeight))
    let size = NSSize(width: 380, height: boundedHeight)
    if preferredContentSize != size {
      preferredContentSize = size
    }
  }

  /// Starts a coalescible one-second timer that changes only countdown strings.
  private func startCountdownTimer() {
    countdownTimer?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else {
        return
      }
      let now = Date()
      self.sevenDayView.updateCountdown(now: now)
      self.fiveHourView.updateCountdown(now: now)
      for row in self.creditRows {
        row.updateCountdown(now: now)
      }
    }
    timer.tolerance = 0.15
    countdownTimer = timer
  }

  /// Handles the icon-only manual refresh command.
  @objc private func refreshClicked() {
    store.refreshAll()
  }

  /// Handles the icon-only settings command through the app delegate callback.
  @objc private func settingsClicked() {
    onOpenSettings?()
  }

  /// Terminates the accessory application without leaving a status item behind.
  @objc private func quitClicked() {
    NSApplication.shared.terminate(nil)
  }
}

/// 在原生弹窗的毛玻璃上叠加色调，露出背景模糊并维持内容的辨识度。
private final class PopoverTintView: NSView {
  /// 将当前外观的半透明色调绘制到需要更新的区域，由 AppKit 与原生材质合成。
  override func draw(_ dirtyRect: NSRect) {
    QuotaPopoverColors.backdropTint.setFill()
    NSBezierPath(rect: dirtyRect).fill()
  }

  /// 系统外观切换后按新的颜色和不透明度重画色调。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
