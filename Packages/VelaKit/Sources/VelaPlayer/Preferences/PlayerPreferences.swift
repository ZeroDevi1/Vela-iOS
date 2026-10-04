import Foundation
import Observation

/// 播放偏好，持久化在 UserDefaults。修改即时生效；正在播放的会话在下次读取时使用新值。
@MainActor
@Observable
public final class PlayerPreferences {
    private enum Key {
        static let seekBackward = "player.seekBackwardSeconds"
        static let seekForward = "player.seekForwardSeconds"
        static let holdSpeed = "player.holdSpeed"
        static let brightnessVolume = "player.gesture.brightnessVolume"
        static let swipeSeek = "player.gesture.swipeSeek"
        static let autoSkipIntro = "player.autoSkipIntro"
        static let autoPlayNext = "player.autoPlayNext"
        static let subtitleScale = "player.subtitle.scale"
        static let subtitleBottomOffset = "player.subtitle.bottomOffset"
    }

    /// 可选的快进 / 快退秒数。
    public static let seekIntervals: [Int] = [5, 10, 15, 30, 60]
    /// 可选的长按倍速。
    public static let holdSpeeds: [Float] = [1.5, 2, 2.5, 3]

    @ObservationIgnored private let defaults: UserDefaults

    public var seekBackwardSeconds: Int { didSet { defaults.set(seekBackwardSeconds, forKey: Key.seekBackward) } }
    public var seekForwardSeconds: Int { didSet { defaults.set(seekForwardSeconds, forKey: Key.seekForward) } }
    public var holdSpeed: Float { didSet { defaults.set(holdSpeed, forKey: Key.holdSpeed) } }
    public var enableBrightnessVolume: Bool { didSet { defaults.set(enableBrightnessVolume, forKey: Key.brightnessVolume) } }
    public var enableSwipeSeek: Bool { didSet { defaults.set(enableSwipeSeek, forKey: Key.swipeSeek) } }
    /// 进入片头区段时直接跳过；关闭时只显示「跳过片头」按钮。
    public var autoSkipIntro: Bool { didSet { defaults.set(autoSkipIntro, forKey: Key.autoSkipIntro) } }
    /// 剧集结束后倒计时自动播放下一集。
    public var autoPlayNext: Bool { didSet { defaults.set(autoPlayNext, forKey: Key.autoPlayNext) } }
    /// 字幕字号倍率，0.6...2.0。
    public var subtitleScale: Double { didSet { defaults.set(subtitleScale, forKey: Key.subtitleScale) } }
    /// 字幕距画面底部的额外距离（pt），0...200。
    public var subtitleBottomOffset: Double { didSet { defaults.set(subtitleBottomOffset, forKey: Key.subtitleBottomOffset) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seekBackwardSeconds = defaults.object(forKey: Key.seekBackward) as? Int ?? 10
        seekForwardSeconds = defaults.object(forKey: Key.seekForward) as? Int ?? 10
        holdSpeed = defaults.object(forKey: Key.holdSpeed) as? Float ?? 2
        enableBrightnessVolume = defaults.object(forKey: Key.brightnessVolume) as? Bool ?? true
        enableSwipeSeek = defaults.object(forKey: Key.swipeSeek) as? Bool ?? true
        autoSkipIntro = defaults.object(forKey: Key.autoSkipIntro) as? Bool ?? false
        autoPlayNext = defaults.object(forKey: Key.autoPlayNext) as? Bool ?? true
        subtitleScale = defaults.object(forKey: Key.subtitleScale) as? Double ?? 1
        subtitleBottomOffset = defaults.object(forKey: Key.subtitleBottomOffset) as? Double ?? 0
    }

    /// 手势相关的快照，交给播放控制器使用。
    public var gestureSettings: PlayerGestureSettings {
        var settings = PlayerGestureSettings()
        settings.seekBackwardSeconds = TimeInterval(seekBackwardSeconds)
        settings.seekForwardSeconds = TimeInterval(seekForwardSeconds)
        settings.holdSpeed = holdSpeed
        settings.enableBrightnessVolume = enableBrightnessVolume
        settings.enableSwipeSeek = enableSwipeSeek
        return settings
    }
}
