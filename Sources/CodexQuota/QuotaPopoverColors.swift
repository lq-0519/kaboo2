import AppKit

/// 弹窗内共用的浅色与深色配色，协调原生毛玻璃、文字和卡片的对比度。
enum QuotaPopoverColors {
  /// 原生毛玻璃上的半透明色调。深色外观较浓，以压低后方亮色窗口的亮度。
  static let backdropTint = adaptive(light: 0xf6f7fa, dark: 0x23262b, lightAlpha: 0.68, darkAlpha: 0.80)

  /// 重置卡叠加轻薄的半透明底色，让卡片跟随弹窗背景的明度变化。
  static let cardBackground = adaptive(light: 0x425068, dark: 0xf1f4f8, lightAlpha: 0.05, darkAlpha: 0.07)

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

  /// 由 AppKit 按视图当前外观解析 sRGB 色值和各自的不透明度，默认生成实色。
  private static func adaptive(
    light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let value = isDark ? dark : light
      return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: isDark ? darkAlpha : lightAlpha
      )
    }
  }
}
