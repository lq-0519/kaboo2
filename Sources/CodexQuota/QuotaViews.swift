import AppKit

/// Lightweight native progress bar that supports a continuously computed fill color.
final class QuotaProgressView: NSView {
  /// Remaining quota normalized to the closed zero-to-one drawing range.
  private var normalizedValue: Double = 0

  /// Current semantic fill color supplied by the owning quota row.
  private var fillColor = NSColor.tertiaryLabelColor

  /// Prevents construction from archived interface files because the UI is programmatic.
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Creates an unlayered view whose drawing cost is paid only when quota data changes.
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
  }

  /// Updates the normalized amount and color before requesting one AppKit redraw.
  func update(remainingPercent: Double, color: NSColor) {
    normalizedValue = min(1, max(0, remainingPercent / 100))
    fillColor = color
    needsDisplay = true
  }

  /// Draws an adaptive neutral track and a rounded colored fill segment.
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let radius = bounds.height / 2
    let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    NSColor.separatorColor.withAlphaComponent(0.32).setFill()
    track.fill()

    let fillWidth = bounds.width * normalizedValue
    guard fillWidth > 0 else {
      return
    }
    let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
    let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
    fillColor.setFill()
    fill.fill()
  }
}

/// Unframed quota section showing one percentage, progress bar, countdown, and exact time.
final class QuotaRowView: NSView {
  /// Semantic title identifying the rolling window.
  private let titleLabel = NSTextField(labelWithString: "")

  /// Strong remaining percentage aligned with the title.
  private let percentLabel = NSTextField(labelWithString: "--% 剩余")

  /// Horizontal bar whose value follows the remaining percentage.
  private let progress = QuotaProgressView()

  /// Relative reset countdown updated locally while the popover is visible.
  private let countdownLabel = NSTextField(labelWithString: "等待数据")

  /// Absolute reset timestamp rendered in the current timezone.
  private let exactLabel = NSTextField(labelWithString: "未提供精确时间")

  /// Latest window retained so one-second ticks never require reconstruction.
  private var quotaWindow: QuotaWindow?

  /// Creates and constrains the compact quota hierarchy.
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = QuotaPopoverColors.primaryText
    percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    percentLabel.textColor = QuotaPopoverColors.primaryText
    percentLabel.alignment = .right

    countdownLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    countdownLabel.textColor = QuotaPopoverColors.secondaryText
    exactLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    exactLabel.textColor = QuotaPopoverColors.secondaryText

    let heading = NSStackView(views: [titleLabel, NSView(), percentLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 8

    let stack = NSStackView(views: [heading, progress, countdownLabel, exactLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
      progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
      progress.heightAnchor.constraint(equalToConstant: 6),
    ])
  }

  /// Prevents construction from archived interface files because the app is fully programmatic.
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Replaces the window data and refreshes all static and time-sensitive labels.
  func update(window: QuotaWindow?, fallbackKind: QuotaKind) {
    quotaWindow = window
    titleLabel.stringValue = fallbackKind.displayName
    percentLabel.stringValue = "\(DisplayFormatter.percent(window?.remainingPercent)) 剩余"
    let remainingPercent = window?.remainingPercent ?? 0
    let color =
      window.map {
        progressColor(for: $0.remainingPercent)
      } ?? .tertiaryLabelColor
    progress.update(remainingPercent: remainingPercent, color: color)
    exactLabel.stringValue = DisplayFormatter.exact(window?.resetsAt)
    updateCountdown()
  }

  /// Recomputes only the relative text from the retained absolute reset instant.
  func updateCountdown(now: Date = Date()) {
    countdownLabel.stringValue =
      quotaWindow == nil
      ? "等待额度数据"
      : DisplayFormatter.resetCountdown(until: quotaWindow?.resetsAt, now: now)
  }

  /// Maps remaining quota continuously from red through orange and yellow to green.
  private func progressColor(for remainingPercent: Double) -> NSColor {
    let normalized = min(100, max(0, remainingPercent)) / 100
    let hue = normalized * 0.35
    return NSColor(
      calibratedHue: hue,
      saturation: 0.82,
      brightness: 0.88,
      alpha: 1
    )
  }
}

/// 在弹窗内展示一张重置卡的名称、到期倒计时和准确时间。
final class ResetCreditRowView: NSView {
  /// 服务返回的卡片名称，过长时只截短末尾。
  private let titleLabel = NSTextField(labelWithString: "")

  /// 右侧到期倒计时，弹窗可见时在本地更新。
  private let countdownLabel = NSTextField(labelWithString: "")

  /// 第二行展示当前时区下的准确到期时间。
  private let exactLabel = NSTextField(labelWithString: "")

  /// 卡片数据用于计算倒计时，更新文字时无需重建视图。
  private let credit: ResetCredit

  /// 将名称和倒计时放在同一行，准确时间单独排在下方。
  init(credit: ResetCredit) {
    self.credit = credit
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.stringValue = credit.title
    titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    titleLabel.textColor = QuotaPopoverColors.primaryText
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    countdownLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    countdownLabel.textColor = QuotaPopoverColors.primaryText
    countdownLabel.alignment = .right
    countdownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    exactLabel.stringValue =
      credit.expiresAt.map {
        "到期：\(DisplayFormatter.exact($0))"
      } ?? "无到期时间"
    exactLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    exactLabel.textColor = QuotaPopoverColors.secondaryText

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let heading = NSStackView(views: [titleLabel, spacer, countdownLabel])
    heading.orientation = .horizontal
    heading.alignment = .firstBaseline
    heading.spacing = 5

    let stack = NSStackView(views: [heading, exactLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 3
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    updateCountdown()
  }

  /// 卡片由代码创建，不支持从归档界面初始化。
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// 绘制与弹窗底色接近的圆角背景，使用一个物理像素宽的细边框。
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let borderWidth = 1 / (window?.backingScaleFactor ?? 1)
    let inset = borderWidth / 2
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 8, yRadius: 8)
    QuotaPopoverColors.cardBackground.setFill()
    path.fill()
    QuotaPopoverColors.border.setStroke()
    path.lineWidth = borderWidth
    path.stroke()
  }

  /// 只更新当前倒计时文字，保留卡片视图和已布局的时间字段。
  func updateCountdown(now: Date = Date()) {
    countdownLabel.stringValue = DisplayFormatter.expiryCountdown(
      until: credit.expiresAt,
      now: now
    )
  }
}

/// Flipped document view that lets the scroll view lay content from top to bottom naturally.
final class FlippedDocumentView: NSView {
  /// Uses a top-left coordinate origin suitable for a vertically growing popover document.
  override var isFlipped: Bool {
    true
  }
}
