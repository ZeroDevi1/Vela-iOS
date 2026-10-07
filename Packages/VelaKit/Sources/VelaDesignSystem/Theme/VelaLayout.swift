import SwiftUI

/// 按容器宽度分档的版式度量。
///
/// 尺寸类别（size class）在 iPad 分屏、Mac 窗口缩放时只有 compact / regular 两档，且 regular 覆盖从 700pt 到 1400pt
/// 的跨度，无法区分「iPad 竖屏」与「Mac 全屏」。这里按页面实际可用宽度分三档，页面边距、卡片宽度、头图高度都从这里取，
/// 避免各处散落 `isCompact ? a : b`。
public enum VelaLayout: Int, Comparable, Sendable {
    /// < 700pt：iPhone、iPad 1/3 分屏。保持 iPhone 竖排版式。
    case compact
    /// 700–1100pt：iPad 竖屏、1/2 分屏、较窄的 Mac 窗口。
    case regular
    /// > 1100pt：iPad 横屏、Mac 大窗口。
    case expanded

    public init(width: CGFloat) {
        switch width {
        case ..<700: self = .compact
        case ..<1100: self = .regular
        default: self = .expanded
        }
    }

    /// 同时考虑高度：iPhone 横屏宽度可达 950pt，但只有约 400pt 高，放不下沉浸式头图与大卡片，仍按 compact。
    public init(size: CGSize) {
        self = size.height < 500 ? .compact : VelaLayout(width: size.width)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 是否使用宽屏版式（左信息 / 右操作列的头图、横向单集卡等）。
    public var isWide: Bool { self >= .regular }

    /// 页面左右边距；所有横滑分区的首尾留白与之对齐。
    public var pageMargin: CGFloat {
        switch self {
        case .compact: VelaTheme.Spacing.l
        case .regular: 32
        case .expanded: 50
        }
    }

    /// 一屏可见的 16:9 单集卡数量（用于 `containerRelativeFrame` 计算卡片宽度）。
    public var visibleEpisodeCards: Int {
        switch self {
        case .compact: 1
        case .regular: 3
        case .expanded: 4
        }
    }

    /// 沉浸式头图占可视高度的比例：宽屏首屏几乎全是画面，iPhone 留出播放按钮与简介。
    public var heroHeightFraction: CGFloat {
        switch self {
        case .compact: 0.62
        case .regular: 0.72
        case .expanded: 0.86
        }
    }

    /// 横版（16:9）卡片宽度：继续观看、发现页横卡等。
    public var landscapeCardWidth: CGFloat {
        switch self {
        case .compact: 260
        case .regular: 320
        case .expanded: 360
        }
    }

    public var posterWidth: CGFloat {
        switch self {
        case .compact: 116
        case .regular: 150
        case .expanded: 170
        }
    }
}

extension EnvironmentValues {
    /// 当前页面的版式分档；由 `measuresVelaLayout()` 按容器宽度写入，未测量时按 compact 处理。
    @Entry public var velaLayout: VelaLayout = .compact
}

extension View {
    /// 测量本视图的宽度并把对应的 `VelaLayout` 写入子视图环境。放在页面根视图上（ScrollView 外层），
    /// 这样 iPad 侧边栏展开 / 分屏时按内容区的实际宽度分档，而不是整窗宽度。
    public func measuresVelaLayout() -> some View {
        modifier(VelaLayoutReader())
    }
}

private struct VelaLayoutReader: ViewModifier {
    @State private var layout: VelaLayout = .compact

    func body(content: Content) -> some View {
        content
            .environment(\.velaLayout, layout)
            .onGeometryChange(for: VelaLayout.self) { VelaLayout(size: $0.size) } action: { layout = $0 }
    }
}

extension View {
    /// 左右各留 `VelaLayout.pageMargin`，使页面内各分区与横滑卡片的首尾对齐。
    public func velaPageMargin() -> some View {
        modifier(PageMarginPadding())
    }
}

private struct PageMarginPadding: ViewModifier {
    @Environment(\.velaLayout) private var layout

    func body(content: Content) -> some View {
        content.padding(.horizontal, layout.pageMargin)
    }
}

extension View {
    /// 卡片画面的指针悬停反馈：iPad 指针用系统 lift 效果（按卡片圆角取形状），Mac 鼠标悬停时轻微放大。
    /// 纯触屏操作没有悬停事件，不受影响。只加在画面上，标题文字不跟着缩放。
    public func velaCardHover(cornerRadius: CGFloat = VelaTheme.Radius.card) -> some View {
        modifier(CardHover(cornerRadius: cornerRadius))
    }
}

private struct CardHover: ViewModifier {
    let cornerRadius: CGFloat
    #if os(macOS)
    @State private var hovering = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: 12, y: 6)
            .animation(.snappy(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
        #else
        content
            .contentShape(.hoverEffect, .rect(cornerRadius: cornerRadius))
            .hoverEffect(.lift)
        #endif
    }
}
