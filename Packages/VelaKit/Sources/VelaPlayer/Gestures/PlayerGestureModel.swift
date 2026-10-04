import CoreGraphics
import Foundation

/// 播放器手势的纯判定逻辑，与 UIKit / AppKit 解耦以便单测和跨平台复用。
///
/// 交互约定（参考 Infuse / SenPlayer 与 Vela Android）：
/// - 单击：显隐控制层；两侧区域等待双击超时后再响应。
/// - 双击：左侧快退、右侧快进、中间播放 / 暂停。
/// - 水平拖动：调整进度（松手后才真正跳转，过程中只预览）。
/// - 左侧竖直拖动：亮度；右侧竖直拖动：音量（仅 iOS / iPadOS）。
/// - 长按：临时倍速，松手恢复。
/// - 双指捏合：适应 / 填充画面切换。
public enum PlayerGestureModel {
    public enum TapZone: Equatable, Sendable {
        case leading, center, trailing
    }

    public enum PanKind: Equatable, Sendable {
        case seek
        case brightness
        case volume
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
    ///   - threshold: 判定方向所需的最小位移（pt），低于时返回 nil 继续等待。
    public static func panKind(
        translation: CGSize,
        startX: CGFloat,
        width: CGFloat,
        threshold: CGFloat = 12
    ) -> PanKind? {
        let dx = abs(translation.width)
        let dy = abs(translation.height)
        guard max(dx, dy) >= threshold else { return nil }
        if dx > dy { return .seek }
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

    /// 捏合缩放超过该比例时切换适应 / 填充。
    public static let pinchToggleThreshold: CGFloat = 0.12
}

/// 用户可调的手势参数。
public struct PlayerGestureSettings: Sendable, Hashable {
    public var seekBackwardSeconds: TimeInterval = 10
    public var seekForwardSeconds: TimeInterval = 10
    /// 长按临时倍速。
    public var holdSpeed: Float = 2
    public var enableBrightnessVolume = true
    public var enableSwipeSeek = true

    public init() {}
}
