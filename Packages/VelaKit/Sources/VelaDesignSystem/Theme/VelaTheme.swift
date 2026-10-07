import SwiftUI

/// Vela 设计令牌。颜色以系统语义色为主，只有品牌强调色是自定义的，确保深浅色、增强对比度与 Liquid Glass 下都能正确适配。
public enum VelaTheme {
    public static let accentDeep = Color(red: 0x15 / 255, green: 0x65 / 255, blue: 0xC0 / 255)
    public static let accentLight = Color(red: 0x64 / 255, green: 0xB5 / 255, blue: 0xF6 / 255)

    /// 品牌蓝（`branding/vela`）用作 tint：浅色模式用 #1565C0，深色模式用 #64B5F6，
    /// 保证按钮白字与浅底文字都满足 4.5:1 对比度。
    public static let accent = Color(light: accentDeep, dark: accentLight)
    /// 品牌紫（#7C4DFF），仅用于少量装饰性强调。
    public static let accentSecondary = Color(red: 0x7C / 255, green: 0x4D / 255, blue: 0xFF / 255)

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        /// 海报卡片。
        public static let card: CGFloat = 12
        /// 宽幅卡片与面板。
        public static let panel: CGFloat = 20
    }

    // 卡片宽度、页面边距等随容器宽度变化的度量见 `VelaLayout`。
}

extension Color {
    /// 随系统外观切换的颜色。
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}
