import AppKit

/// 展示今日额度消耗和最近七个本地自然日的柱状图，使用系统颜色适配浅色和深色外观。
final class DailyQuotaUsageView: NSView {
  /// 今日用量入口始终和历史图表同屏，缺少有效样本时显示暂无数据。
  private let todayLabel = NSTextField(labelWithString: "今日暂无数据")

  /// 说明柱状图统计的是七天额度，并解释不完整的记录。
  private let detailLabel = NSTextField(labelWithString: "按一轮 7 天额度统计")

  /// 共享百分比刻度的原生柱状图，每日一列。
  private let chart = DailyQuotaUsageChartView()

  /// 保留上次渲染的数据，避免重置卡刷新等无关更新触发图表重绘。
  private var days: [DailyQuotaUsageDay] = []

  /// 构建紧凑的历史区，使用和下方额度行一致的字号与自适应布局。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "7 天额度消耗趋势")
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    todayLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    todayLabel.alignment = .right
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.textColor = .secondaryLabelColor

    let heading = NSStackView(views: [title, NSView(), todayLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 8

    let stack = NSStackView(views: [heading, chart, detailLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
      chart.widthAnchor.constraint(equalTo: stack.widthAnchor),
      chart.heightAnchor.constraint(equalToConstant: 113),
    ])
  }

  /// 该视图通过程序化布局构建。
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// 读取由旧到新排列的自然日记录，末列为今天。只在数据变化时更新标签和图表。
  func update(days: [DailyQuotaUsageDay]) {
    guard self.days != days else { return }
    self.days = days

    if let today = days.last?.usedPercent {
      todayLabel.stringValue = "今日已用约 \(Self.percent(today))"
      todayLabel.textColor = .labelColor
    } else {
      todayLabel.stringValue = "今日暂无数据"
      todayLabel.textColor = .secondaryLabelColor
    }

    if !days.contains(where: { $0.usedPercent != nil }) {
      detailLabel.stringValue = "按一轮 7 天额度统计，等待积累用量记录"
    } else if days.contains(where: { $0.usedPercent != nil && $0.isPartial }) {
      detailLabel.stringValue = "按一轮 7 天额度统计，淡色表示记录不完整"
    } else {
      detailLabel.stringValue = "按一轮 7 天额度统计"
    }
    chart.update(days: days)
  }

  /// 保留一位小数，并把未达到显示精度的正数与真正的零区分开。
  fileprivate static func percent(_ value: Double) -> String {
    if value > 0 && value < 0.1 { return "<0.1%" }
    let rounded = (value * 10).rounded() / 10
    return String(format: rounded.rounded() == rounded ? "%.0f%%" : "%.1f%%", rounded)
  }
}

/// 绘制同一纵轴上的七个日用量柱，每列使用原生提示和辅助功能标签提供完整数值。
private final class DailyQuotaUsageChartView: NSView {
  /// 保留左侧刻度列，绘图与原生提示热区共享同一宽度。
  private let axisWidth: CGFloat = 39

  /// 每日一项的提示和 VoiceOver 热区，由固定列布局平均分配屏幕宽度。
  private let columns = (0..<7).map { _ in NSView() }

  /// 与每一列对应的用量、日期和采样完整状态，由旧到新排列。
  private var days: [DailyQuotaUsageDay] = []

  /// 纵轴上限为最高日用量加 15 个百分点，最多显示到 100%。暂无记录时以 0% 为基准。
  private var axisMaximum: Double = 15

  /// 按本机时区生成简短日期标签和悬停信息，更新时读取当前时区。
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }

  /// 创建没有额外绘制开销的原生列视图，供鼠标悬停与 VoiceOver 定位。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false

    let layout = NSStackView(views: columns)
    layout.orientation = .horizontal
    layout.alignment = .centerY
    layout.distribution = .fillEqually
    layout.spacing = 0
    layout.translatesAutoresizingMaskIntoConstraints = false
    addSubview(layout)

    NSLayoutConstraint.activate([
      layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: axisWidth),
      layout.trailingAnchor.constraint(equalTo: trailingAnchor),
      layout.topAnchor.constraint(equalTo: topAnchor),
      layout.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    for column in columns {
      column.translatesAutoresizingMaskIntoConstraints = false
      column.heightAnchor.constraint(equalTo: layout.heightAnchor).isActive = true
      column.setAccessibilityRole(.staticText)
    }
  }

  /// 图表通过程序化布局构建。
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// 应用新快照时重算纵轴，并为每个自然日同步一份可悬停和朗读的记录说明。
  func update(days: [DailyQuotaUsageDay]) {
    self.days = Array(days.suffix(columns.count))
    let maximum = self.days.compactMap(\.usedPercent).max() ?? 0
    axisMaximum = min(100, maximum + 15)

    for (index, column) in columns.enumerated() {
      let description = self.days.indices.contains(index) ? dayDescription(at: index) : nil
      column.toolTip = description
      column.setAccessibilityElement(description != nil)
      column.setAccessibilityLabel(description)
    }
    needsDisplay = true
  }

  /// 系统切换外观时刷新自绘内容，让网格、柱和文字使用新外观下的语义颜色。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// 绘制共用百分比刻度、每天的柱和值。缺失列留空，已知的零在基线上标记。
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let plot = NSRect(x: axisWidth, y: 17, width: bounds.width - axisWidth, height: bounds.height - 36)
    guard plot.width > 0, plot.height > 0 else { return }

    let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    for index in 0...4 {
      let fraction = Double(index) / 4
      let tick = axisMaximum * fraction
      let y = (plot.minY + plot.height * CGFloat(fraction)).rounded() + 0.5
      let line = NSBezierPath()
      line.move(to: NSPoint(x: plot.minX, y: y))
      line.line(to: NSPoint(x: plot.maxX, y: y))
      NSColor.separatorColor.setStroke()
      line.lineWidth = 1
      line.stroke()
      drawText(
        DailyQuotaUsageView.percent(tick), font: axisFont, color: .secondaryLabelColor,
        alignedAt: NSPoint(x: plot.minX - 5, y: y), rightAligned: true
      )
    }

    let width = plot.width / CGFloat(columns.count)
    for (index, day) in days.enumerated() {
      let isToday = index == days.count - 1
      let x = plot.minX + width * (CGFloat(index) + 0.5)
      let date = calendar.dateComponents([.month, .day], from: day.date)
      let dateText = isToday ? "今天" : "\(date.month ?? 0)/\(date.day ?? 0)"
      let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: isToday ? .semibold : .regular)
      let textColor: NSColor = isToday ? .controlAccentColor : .secondaryLabelColor
      drawText(dateText, font: dateFont, color: textColor, alignedAt: NSPoint(x: x, y: 7))

      guard let value = day.usedPercent else { continue }
      // 同日多次重置可能使总用量超过 100%，柱高封顶，柱上文字仍显示实际值。
      let height = max(2, plot.height * CGFloat(min(value, axisMaximum) / axisMaximum))
      let barWidth = min(20, width * 0.55)
      let bar = NSRect(x: x - barWidth / 2, y: plot.minY, width: barWidth, height: height)
      let barColor: NSColor = isToday ? .controlAccentColor : .secondaryLabelColor
      barColor.withAlphaComponent(day.isPartial ? 0.30 : 0.75).setFill()
      let corner = min(3, height / 2)
      NSBezierPath(roundedRect: bar, xRadius: corner, yRadius: corner).fill()
      drawText(
        DailyQuotaUsageView.percent(value), font: dateFont, color: textColor,
        alignedAt: NSPoint(x: x, y: bar.maxY + 8)
      )
    }
  }

  /// 生成悬停和 VoiceOver 共用的日期、观察用量与完整状态说明。
  private func dayDescription(at index: Int) -> String {
    let day = days[index]
    let date = calendar.dateComponents([.month, .day], from: day.date)
    let dateText = "\(date.month ?? 0)月\(date.day ?? 0)日"
    guard let value = day.usedPercent else { return "\(dateText)，暂无数据" }
    let partial = day.isPartial ? "，记录不完整" : ""
    return "\(dateText)，已用约 \(DailyQuotaUsageView.percent(value))\(partial)"
  }

  /// 把坐标文字垂直居中，轴标签右对齐，日标签和用量在柱的水平中点居中。
  private func drawText(
    _ text: String, font: NSFont, color: NSColor, alignedAt point: NSPoint, rightAligned: Bool = false
  ) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let label = text as NSString
    let size = label.size(withAttributes: attributes)
    let origin = NSPoint(
      x: point.x - (rightAligned ? size.width : size.width / 2), y: point.y - size.height / 2
    )
    label.draw(at: origin, withAttributes: attributes)
  }
}
