import AppKit

/// 弹窗内共用的浅色与深色配色，在固定底色上保持文字、图表和卡片的对比度。
enum QuotaPopoverColors {
  /// 不透明的弹窗内容底色，防止窗口背后的亮色内容影响文字辨识。
  static let background = adaptive(light: 0xf6f7fa, dark: 0x23262b)

  /// 与内容底色相邻的卡片底色，用轻微的明度差区分重置卡。
  static let cardBackground = adaptive(light: 0xeff1f5, dark: 0x2d3036)

  /// 用于卡片轮廓和图表网格的低对比度描边。
  static let border = adaptive(light: 0xd8dee7, dark: 0x444b55)

  /// 标题和关键数字所用的高对比度文字。
  static let primaryText = adaptive(light: 0x202735, dark: 0xf1f4f8)

  /// 坐标、说明和日期使用的辅助文字，在弹窗和卡片底色上均保持清晰。
  static let secondaryText = adaptive(light: 0x515c6e, dark: 0xc4cdd9)

  /// 今日标签和标题栏按钮使用的蓝色，在两种外观中都能清楚辨认。
  static let accentText = adaptive(light: 0x174fa8, dark: 0xa5ccff)

  /// 今日柱的强调蓝，与历史柱保持区别。
  static let todayBar = adaptive(light: 0x2e6bc7, dark: 0x80b5ff)

  /// 历史柱使用低饱和度的蓝灰色，保留与图表底色的明度差。
  static let historyBar = adaptive(light: 0x57718e, dark: 0x91a9c8)

  /// 由 AppKit 按视图当前外观解析 sRGB 色值，切换系统外观时随视图刷新。
  private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1
      )
    }
  }
}
