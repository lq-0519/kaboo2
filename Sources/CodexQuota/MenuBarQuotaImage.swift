import AppKit
import CoreText

/// Builds the complete two-row menu-bar presentation as one image so AppKit can apply
/// native status-item highlighting and inactive-state treatment to the whole surface.
enum MenuBarQuotaImage {
  /// Produces two centered columns with independently selected percentage or pie primary rows.
  /// Percentages follow the configured font size, while pies keep a thirteen-point canvas and time rows use
  /// the battery monitor's nine-point secondary hierarchy inside a stable 22-point canvas.
  /// Time labels come from the caller's shared presentation so image, cache and tooltip agree.
  static func make(
    fiveHourWindow: QuotaWindow?,
    sevenDayWindow: QuotaWindow?,
    fiveHourStyle: MenuBarQuotaDisplayStyle,
    sevenDayStyle: MenuBarQuotaDisplayStyle,
    fiveHourTime: String,
    sevenDayTime: String,
    primaryFontSize: Int,
    dynamicColorsEnabled: Bool
  ) -> NSImage {
    let primaryFont = NSFont.monospacedDigitSystemFont(
      ofSize: CGFloat(primaryFontSize),
      weight: .regular
    )
    let secondaryFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    let fiveHourColor =
      dynamicColorsEnabled
      ? fiveHourWindow.flatMap { quotaColor(for: $0.remainingPercent) } : nil
    let sevenDayColor =
      dynamicColorsEnabled
      ? sevenDayWindow.flatMap { quotaColor(for: $0.remainingPercent) } : nil
    let isTemplate = fiveHourColor == nil && sevenDayColor == nil
    let neutralColor =
      isTemplate
      ? NSColor.black
      : NSColor.controlTextColor.usingColorSpace(.sRGB) ?? .controlTextColor

    let fiveHourTitle = textLine(
      DisplayFormatter.percent(fiveHourWindow?.remainingPercent),
      font: primaryFont,
      color: fiveHourColor ?? neutralColor
    )
    let fiveHourTitleBounds = glyphBounds(of: fiveHourTitle)
    let sevenDayTitle = textLine(
      DisplayFormatter.percent(sevenDayWindow?.remainingPercent),
      font: primaryFont,
      color: sevenDayColor ?? neutralColor
    )
    let sevenDayTitleBounds = glyphBounds(of: sevenDayTitle)
    let fiveHourTimeLine = textLine(
      fiveHourTime,
      font: secondaryFont,
      color: neutralColor
    )
    let fiveHourTimeBounds = glyphBounds(of: fiveHourTimeLine)
    let sevenDayTimeLine = textLine(
      sevenDayTime,
      font: secondaryFont,
      color: neutralColor
    )
    let sevenDayTimeBounds = glyphBounds(of: sevenDayTimeLine)
    let widestPercentageBounds = glyphBounds(
      of: textLine("100%", font: primaryFont, color: neutralColor)
    )
    // Reserve all normal formats across both modes so minute changes and midnight transitions
    // cannot shift the adjacent status items. Glyph ink, rather than character count, sets the width.
    let fiveHourTimeWidth = maximumTextWidth(
      ["5h59", "23:59", "待刷新", "—"],
      font: secondaryFont
    )
    let sevenDayTimeWidth = maximumTextWidth(
      ["7d23", "23h59", "23:59", "12/31", "待刷新", "—"],
      font: secondaryFont
    )

    let pieCanvasSize: CGFloat = 13
    let groupSpacing: CGFloat = 4
    let fiveHourPrimaryWidth =
      fiveHourStyle == .percentage
      ? max(widestPercentageBounds.width, fiveHourTitleBounds.width) : pieCanvasSize
    let sevenDayPrimaryWidth =
      sevenDayStyle == .percentage
      ? max(widestPercentageBounds.width, sevenDayTitleBounds.width) : pieCanvasSize
    let fiveHourWidth = ceil(
      max(
        fiveHourPrimaryWidth,
        max(fiveHourTimeWidth, fiveHourTimeBounds.width)
      )
    )
    let sevenDayWidth = ceil(
      max(
        sevenDayPrimaryWidth,
        max(sevenDayTimeWidth, sevenDayTimeBounds.width)
      )
    )
    let imageSize = NSSize(
      width: max(1, fiveHourWidth + groupSpacing + sevenDayWidth),
      height: 22
    )
    let sevenDayOrigin = fiveHourWidth + groupSpacing

    let image = NSImage(size: imageSize, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else {
        return false
      }
      context.saveGState()
      defer { context.restoreGState() }
      context.textMatrix = .identity

      switch fiveHourStyle {
      case .percentage:
        draw(
          fiveHourTitle,
          bounds: fiveHourTitleBounds,
          origin: 0,
          width: fiveHourWidth,
          regionMinY: 9,
          regionHeight: 13,
          in: context
        )
      case .pie:
        drawPie(
          remainingPercent: fiveHourWindow?.remainingPercent,
          color: fiveHourColor ?? neutralColor,
          rect: CGRect(
            x: (fiveHourWidth - pieCanvasSize) / 2,
            y: 9,
            width: pieCanvasSize,
            height: pieCanvasSize
          ),
          in: context
        )
      }
      draw(
        fiveHourTimeLine,
        bounds: fiveHourTimeBounds,
        origin: 0,
        width: fiveHourWidth,
        regionMinY: 0,
        regionHeight: 9,
        in: context
      )
      switch sevenDayStyle {
      case .percentage:
        draw(
          sevenDayTitle,
          bounds: sevenDayTitleBounds,
          origin: sevenDayOrigin,
          width: sevenDayWidth,
          regionMinY: 9,
          regionHeight: 13,
          in: context
        )
      case .pie:
        drawPie(
          remainingPercent: sevenDayWindow?.remainingPercent,
          color: sevenDayColor ?? neutralColor,
          rect: CGRect(
            x: sevenDayOrigin + (sevenDayWidth - pieCanvasSize) / 2,
            y: 9,
            width: pieCanvasSize,
            height: pieCanvasSize
          ),
          in: context
        )
      }
      draw(
        sevenDayTimeLine,
        bounds: sevenDayTimeBounds,
        origin: sevenDayOrigin,
        width: sevenDayWidth,
        regionMinY: 0,
        regionHeight: 9,
        in: context
      )
      return true
    }
    image.isTemplate = isTemplate
    return image
  }

  /// Creates a Core Text line with one explicit font and color for deterministic glyph measurement.
  private static func textLine(_ text: String, font: NSFont, color: NSColor) -> CTLine {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: color,
        ]
      )
    )
  }

  /// Returns actual glyph-path bounds so each column tracks visible ink instead of character count.
  private static func glyphBounds(of line: CTLine) -> CGRect {
    CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
  }

  /// Measures the widest reference label across display modes to reserve stable column geometry.
  private static func maximumTextWidth(_ samples: [String], font: NSFont) -> CGFloat {
    samples.map { glyphBounds(of: textLine($0, font: font, color: .black)).width }.max() ?? 0
  }

  /// Centers one measured text line inside a fixed column and vertical row without changing its size.
  private static func draw(
    _ line: CTLine,
    bounds: CGRect,
    origin: CGFloat,
    width: CGFloat,
    regionMinY: CGFloat,
    regionHeight: CGFloat,
    in context: CGContext
  ) {
    context.textPosition = CGPoint(
      x: origin + (width - bounds.width) / 2 - bounds.minX,
      y: regionMinY + (regionHeight - bounds.height) / 2 - bounds.minY
    )
    CTLineDraw(line, context)
  }

  /// Draws either quota's remaining fraction clockwise from twelve o'clock inside its primary row.
  private static func drawPie(
    remainingPercent: Double?,
    color: NSColor,
    rect: CGRect,
    in context: CGContext
  ) {
    let circle = rect.insetBy(dx: 0.75, dy: 0.75)
    let center = CGPoint(x: circle.midX, y: circle.midY)
    let radius = min(circle.width, circle.height) / 2
    let fraction = remainingPercent.map {
      CGFloat(min(1, max(0, $0 / 100)))
    }

    context.setFillColor(color.cgColor)
    if let fraction {
      if fraction >= 0.999 {
        context.fillEllipse(in: circle)
      } else if fraction > 0 {
        context.move(to: center)
        context.addArc(
          center: center,
          radius: radius,
          startAngle: .pi / 2,
          endAngle: .pi / 2 - (2 * .pi * fraction),
          clockwise: true
        )
        context.closePath()
        context.fillPath()
      }
    }

    context.setStrokeColor(color.cgColor)
    context.setLineWidth(1.2)
    context.strokeEllipse(in: circle)
  }

  /// Interpolates remaining quota over the shared green, yellow, orange, and red status scale.
  private static func quotaColor(for remainingPercent: Double) -> NSColor? {
    guard remainingPercent.isFinite else {
      return nil
    }
    let severity = (100 - min(100, max(0, remainingPercent))) / 100
    let stops: [(position: Double, color: NSColor)] = [
      (0, .systemGreen),
      (0.5, .systemYellow),
      (0.75, .systemOrange),
      (1, .systemRed),
    ]
    let upper = stops.firstIndex { $0.position >= severity } ?? (stops.count - 1)
    guard upper > 0 else {
      return stops[0].color.usingColorSpace(.sRGB) ?? stops[0].color
    }

    let start = stops[upper - 1]
    let end = stops[upper]
    let fraction = CGFloat((severity - start.position) / (end.position - start.position))
    let first = start.color.usingColorSpace(.sRGB) ?? start.color
    let last = end.color.usingColorSpace(.sRGB) ?? end.color
    return NSColor(
      srgbRed: first.redComponent + (last.redComponent - first.redComponent) * fraction,
      green: first.greenComponent + (last.greenComponent - first.greenComponent) * fraction,
      blue: first.blueComponent + (last.blueComponent - first.blueComponent) * fraction,
      alpha: 1
    )
  }
}
