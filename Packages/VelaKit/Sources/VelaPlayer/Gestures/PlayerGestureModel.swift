import CoreGraphics
import Foundation

/// 播放器手势的纯判定逻辑，与 UIKit / AppKit 解耦以便单测和跨平台复用。
///
/// 交互约定（参考 Infuse / SenPlayer 与 Vela Android），具体动作可在「播放手势」设置中调整：
/// - 单击 / 双击：按点击区域（两侧 / 中间）执行设置的动作。
/// - 水平拖动：调整进度（松手后才真正跳转，过程中只预览）。
/// - 竖直拖动：左侧亮度、右侧音量；开启「中间切换媒体」时中间区域上滑下一集、下滑上一集。
/// - 长按：按左 / 右半屏的倍速临时加速，松手恢复。
/// - 双指：捏合缩放画面、拖动移动画面、单击重置。
public enum PlayerGestureModel {
    public enum TapZone: Equatable, Sendable {
        case leading, center, trailing
    }

    public enum PanKind: Equatable, Sendable {
        case seek
        case brightness
        case volume
        /// 中间区域竖直滑动切换上一集 / 下一集。
        case switchMedia
    }

    /// 横屏两侧各占 22%，竖屏画面窄，两侧放宽到 40% 便于单手操作（与 Android 版一致，约 2:1:2）。
    public static func tapZone(x: CGFloat, width: CGFloat, isLandscape: Bool) -> TapZone {
        guard width > 0 else { return .center }
        let side = isLandscape ? 0.22 : 0.4
        if x < width * side { return .leading }
        if x >= width * (1 - side) { return .trailing }
        return .center
    }

    /// 根据首次超过阈值的位移方向决定本次拖动的含义，之后整个手势保持不变，避免中途从音量跳到进度。
    ///
    /// - Parameters:
    ///   - translation: 自手势开始的累计位移（pt）。
    ///   - startX: 手势起点横坐标。
    ///   - switchMediaZone: 开启「中间切换媒体」时，中间三分之一的竖直滑动判为切换媒体；否则左右各半。
    ///   - threshold: 判定方向所需的最小位移（pt），低于时返回 nil 继续等待。
    public static func panKind(
        translation: CGSize,
        startX: CGFloat,
        width: CGFloat,
        switchMediaZone: Bool = false,
        threshold: CGFloat = 12
    ) -> PanKind? {
        let dx = abs(translation.width)
        let dy = abs(translation.height)
        guard max(dx, dy) >= threshold else { return nil }
        if dx > dy { return .seek }
        if switchMediaZone, startX >= width / 3, startX < width * 2 / 3 { return .switchMedia }
        return startX < width / 2 ? .brightness : .volume
    }

    /// 水平拖动的跳转量（秒）。整屏宽度对应总时长的 1/5，并限制在 1~10 分钟，长片与短片手感接近。
    public static func seekOffset(translationX: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard width > 0 else { return 0 }
        let fullRange = duration > 0 ? min(max(duration / 5, 60), 600) : 600
        return TimeInterval(translationX / width) * fullRange
    }

    /// 竖直拖动的数值变化：向上为增加，整段视图高度对应 0→1。
    public static func levelDelta(translationY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double(-translationY / height)
    }

    /// 切换媒体需要的最小竖直位移（pt），避免轻微滑动误触。
    public static let switchMediaDistance: CGFloat = 80

    /// 关闭「双指缩放画面」时，捏合超过该比例切换适应 / 填充。
    public static let pinchToggleThreshold: CGFloat = 0.12

    /// 画面缩放范围。
    public static let zoomRange: ClosedRange<CGFloat> = 1...4
}
