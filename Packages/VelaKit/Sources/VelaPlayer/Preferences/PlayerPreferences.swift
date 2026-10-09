import Foundation
import Observation
import VelaCore

/// 播放偏好，持久化在 UserDefaults。修改即时保存；播放器直接引用本对象，多数选项在播放中即时生效，
/// 涉及选流 / 内核参数的选项（解码、缓存、音频能力）在下次起播时生效。
@MainActor
@Observable
public final class PlayerPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - 可选值

    /// 可选的快进 / 快退秒数。
    public static let seekIntervals: [Int] = [5, 10, 15, 30, 60]
    /// 可选的长按 / 双击倍速。
    public static let speedOptions: [Float] = [1.25, 1.5, 2, 2.5, 3]
    /// macOS 长按方向键的可选倍速（左键常用于慢放，含小于 1 的值）。
    public static let keyHoldSpeedOptions: [Float] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 2.5, 3]
    /// macOS「数字键切换倍速」：0 为 0.5×，1–4 为对应倍速。
    public static let digitKeySpeeds: [Character: Float] = ["0": 0.5, "1": 1, "2": 2, "3": 3, "4": 4]
    /// 可选的前向缓冲时长（秒）；0 为自动。
    public static let forwardBufferOptions: [Int] = [0, 15, 30, 60, 120]
    /// 软件解码线程数；0 为自动（按 CPU 核心数）。
    public static let decodeThreadOptions: [Int] = [0, 1, 2, 4, 6, 8]
    /// 控制栏自动隐藏秒数；0 为不自动隐藏。
    public static let autoHideOptions: [Int] = [3, 5, 8, 10, 0]
    /// 预加载下一集的进度阈值（%）；0 为禁用。
    public static let preloadOptions: [Int] = [0, 50, 80, 90]
    /// 音轨 / 字幕首选语言（ISO 639-2，与服务器 `Language` 字段一致）；空串为服务器默认。
    public static let languageOptions: [(code: String, title: String)] = [
        ("", "默认"), ("chi", "中文"), ("yue", "粤语"), ("eng", "英语"), ("jpn", "日语"), ("kor", "韩语"),
        ("fre", "法语"), ("ger", "德语"), ("spa", "西班牙语"), ("rus", "俄语")
    ]

    // MARK: - 内核与缓存

    /// 播放内核：自动（系统优先）/ 系统 / KSPlayer。
    public var engineMode: PlaybackEngineMode { didSet { save(engineMode.rawValue, "player.engineMode") } }
    /// 前向缓冲（秒），0 为自动。系统内核用作 `preferredForwardBufferDuration`，KSPlayer 用作最大缓冲时长。
    public var forwardBufferSeconds: Int { didSet { save(forwardBufferSeconds, "player.forwardBufferSeconds") } }
    /// KSPlayer 首选解码：硬解（VideoToolbox）/ 软解（FFmpeg CPU）。系统内核始终硬解。
    public var decodeMode: DecodeMode { didSet { save(decodeMode.rawValue, "player.decodeMode") } }
    public var softwareDecodeThreads: Int { didSet { save(softwareDecodeThreads, "player.softwareDecodeThreads") } }

    // MARK: - 视频截图

    public var screenshotFormat: ScreenshotFormat { didSet { save(screenshotFormat.rawValue, "player.screenshotFormat") } }
    /// JPEG / HEIC 压缩质量，0.1...1。
    public var screenshotQuality: Double { didSet { save(screenshotQuality, "player.screenshotQuality") } }
    /// 截图后直接保存到相册（仅请求「添加照片」权限），否则弹出分享面板。
    public var screenshotSavesToPhotos: Bool { didSet { save(screenshotSavesToPhotos, "player.screenshotSavesToPhotos") } }

    // MARK: - 音频

    /// 记住在某部剧 / 电影中手动选择的音轨语言，下次播放同一作品时优先选择。
    public var rememberAudioTrack: Bool { didSet { save(rememberAudioTrack, "player.rememberAudioTrack") } }
    public var preferredAudioLanguage: String { didSet { save(preferredAudioLanguage, "player.preferredAudioLanguage") } }
    /// 向服务器声明支持 E-AC3（含杜比全景声 JOC）直通；关闭时服务器把 E-AC3 转为 AC3 / AAC。
    public var enableAtmos: Bool { didSet { save(enableAtmos, "player.enableAtmos") } }
    /// 多声道原样输出（系统空间音频处理）；关闭时声明 2 声道，服务器下混为立体声。
    public var nativeAudio: Bool { didSet { save(nativeAudio, "player.nativeAudio") } }

    // MARK: - 字幕

    public var rememberSubtitle: Bool { didSet { save(rememberSubtitle, "player.rememberSubtitle") } }
    public var preferredSubtitleLanguage: String { didSet { save(preferredSubtitleLanguage, "player.preferredSubtitleLanguage") } }
    /// 「字幕搜索记录」：最近在线搜索字幕用过的语言（ISO 639-2，最新在前，最多 5 个）。
    public var recentSubtitleSearchLanguages: [String] { didSet { save(recentSubtitleSearchLanguages, "player.recentSubtitleSearchLanguages") } }

    /// 记一次字幕搜索语言：移到最前并去重。
    public func rememberSubtitleSearch(language: String) {
        recentSubtitleSearchLanguages = Array(([language] + recentSubtitleSearchLanguages.filter { $0 != language }).prefix(5))
    }
    /// 字幕字号倍率，0.6...2.0。
    public var subtitleScale: Double { didSet { save(subtitleScale, "player.subtitle.scale") } }
    /// 字幕距画面底部的额外距离（pt），0...200。
    public var subtitleBottomOffset: Double { didSet { save(subtitleBottomOffset, "player.subtitle.bottomOffset") } }

    // MARK: - 播放手势

    public var pinchToZoom: Bool { didSet { save(pinchToZoom, "player.gesture.pinchToZoom") } }
    /// 记住缩放倍率，下次播放沿用。
    public var rememberZoom: Bool { didSet { save(rememberZoom, "player.gesture.rememberZoom") } }
    public var savedZoomScale: Double { didSet { save(savedZoomScale, "player.gesture.savedZoomScale") } }
    public var twoFingerPan: Bool { didSet { save(twoFingerPan, "player.gesture.twoFingerPan") } }
    public var twoFingerTapReset: Bool { didSet { save(twoFingerTapReset, "player.gesture.twoFingerTapReset") } }
    /// VR 转平面时跟随设备朝向（陀螺仪）转动视角，可与拖动叠加；设备没有陀螺仪时无效。
    public var vrGyroscope: Bool { didSet { save(vrGyroscope, "player.gesture.vrGyroscope") } }
    public var enableSwipeSeek: Bool { didSet { save(enableSwipeSeek, "player.gesture.swipeSeek") } }
    public var enableBrightnessSwipe: Bool { didSet { save(enableBrightnessSwipe, "player.gesture.brightness") } }
    public var enableVolumeSwipe: Bool { didSet { save(enableVolumeSwipe, "player.gesture.volume") } }
    /// 屏幕中间竖直滑动：上滑下一集、下滑上一集。
    public var enableSwipeSwitchMedia: Bool { didSet { save(enableSwipeSwitchMedia, "player.gesture.switchMedia") } }
    /// 长按播放 / 暂停按钮退出播放器。
    public var longPressPlayPauseExits: Bool { didSet { save(longPressPlayPauseExits, "player.gesture.longPressExit") } }
    /// 长按 / 双击（倍速动作）时左半屏、右半屏使用的倍速。
    public var leadingSpeed: Float { didSet { save(leadingSpeed, "player.gesture.leadingSpeed") } }
    public var trailingSpeed: Float { didSet { save(trailingSpeed, "player.gesture.trailingSpeed") } }
    public var singleTapCenter: PlayerTapAction { didSet { save(singleTapCenter.rawValue, "player.gesture.singleTapCenter") } }
    public var singleTapSides: PlayerTapAction { didSet { save(singleTapSides.rawValue, "player.gesture.singleTapSides") } }
    public var doubleTapCenter: PlayerTapAction { didSet { save(doubleTapCenter.rawValue, "player.gesture.doubleTapCenter") } }
    public var doubleTapSides: PlayerTapAction { didSet { save(doubleTapSides.rawValue, "player.gesture.doubleTapSides") } }
    public var hapticLongPress: Bool { didSet { save(hapticLongPress, "player.haptic.longPress") } }
    public var hapticSwipeSeek: Bool { didSet { save(hapticSwipeSeek, "player.haptic.swipeSeek") } }
    public var hapticScrubBar: Bool { didSet { save(hapticScrubBar, "player.haptic.scrubBar") } }
    /// macOS 键盘：长按 ← / → 时的临时倍速（松开恢复）；短按仍为快退 / 快进。
    public var keyHoldLeftSpeed: Float { didSet { save(keyHoldLeftSpeed, "player.mac.keyHoldLeftSpeed") } }
    public var keyHoldRightSpeed: Float { didSet { save(keyHoldRightSpeed, "player.mac.keyHoldRightSpeed") } }
    /// macOS 键盘：数字键直接设定倍速（`digitKeySpeeds`）。
    public var digitKeysSetSpeed: Bool { didSet { save(digitKeysSetSpeed, "player.mac.digitKeysSetSpeed") } }
    /// macOS 鼠标：在画面上单击 / 双击左右键的动作。
    public var leftClickAction: MouseClickAction { didSet { save(leftClickAction.rawValue, "player.mac.leftClick") } }
    public var leftDoubleClickAction: MouseClickAction { didSet { save(leftDoubleClickAction.rawValue, "player.mac.leftDoubleClick") } }
    public var rightClickAction: MouseClickAction { didSet { save(rightClickAction.rawValue, "player.mac.rightClick") } }
    public var rightDoubleClickAction: MouseClickAction { didSet { save(rightDoubleClickAction.rawValue, "player.mac.rightDoubleClick") } }

    // MARK: - 界面偏好

    public var osd: OSDOptions { didSet { saveCodable(osd, "player.osd") } }
    public var buttons: PlayerButtons { didSet { saveCodable(buttons, "player.buttons") } }
    /// 播放器使用独立亮度：进入时设为上次播放器亮度，退出时恢复系统亮度。
    public var independentBrightness: Bool { didSet { save(independentBrightness, "player.independentBrightness") } }
    public var playerBrightness: Double { didSet { save(playerBrightness, "player.brightness") } }
    public var progressTimeMode: ProgressTimeMode { didSet { save(progressTimeMode.rawValue, "player.progressTimeMode") } }
    /// 控制栏自动隐藏秒数；0 为不自动隐藏。
    public var autoHideSeconds: Int { didSet { save(autoHideSeconds, "player.autoHideSeconds") } }
    public var orientationOnEnter: PlayerOrientation { didSet { save(orientationOnEnter.rawValue, "player.orientationOnEnter") } }
    public var orientationOnSwitch: PlayerOrientation { didSet { save(orientationOnSwitch.rawValue, "player.orientationOnSwitch") } }
    public var landscapeSide: LandscapeSide { didSet { save(landscapeSide.rawValue, "player.landscapeSide") } }
    /// 自动跳过片头前先提示几秒（期间可取消）；关闭则直接跳过。
    public var hintBeforeSkip: Bool { didSet { save(hintBeforeSkip, "player.hint.skip") } }

    // MARK: - 播放

    /// 从上次进度继续；关闭时总是从头播放。
    public var resumePlayback: Bool { didSet { save(resumePlayback, "player.resume") } }
    /// 切到后台（未进入画中画）时继续播放声音；关闭则暂停。
    public var backgroundAudio: Bool { didSet { save(backgroundAudio, "player.backgroundAudio") } }
    /// 回到前台时，若是因切后台而暂停的，自动继续播放。
    public var resumeOnForeground: Bool { didSet { save(resumeOnForeground, "player.resumeOnForeground") } }
    /// 暂停后允许系统自动锁屏；关闭时播放器打开期间始终保持常亮。
    public var lockWhenPaused: Bool { didSet { save(lockWhenPaused, "player.lockWhenPaused") } }
    /// 退到后台时自动进入画中画（还需系统设置中开启「自动开启画中画」）。
    public var autoPictureInPicture: Bool { didSet { save(autoPictureInPicture, "player.autoPiP") } }
    /// 精准定位：跳转到确切的帧；关闭时跳到最近的关键帧，远程片源明显更快。
    public var preciseSeek: Bool { didSet { save(preciseSeek, "player.preciseSeek") } }
    public var seekBackwardSeconds: Int { didSet { save(seekBackwardSeconds, "player.seekBackwardSeconds") } }
    public var seekForwardSeconds: Int { didSet { save(seekForwardSeconds, "player.seekForwardSeconds") } }
    public var scrubPreview: ScrubPreviewMode { didSet { save(scrubPreview.rawValue, "player.scrubPreview") } }
    /// 播放进度超过该百分比时预先请求下一集并让服务器开始准备（转码 / 打开文件）；0 为禁用。
    public var preloadNextPercent: Int { didSet { save(preloadNextPercent, "player.preloadNextPercent") } }
    /// 进入片头区段时直接跳过；关闭时只显示「跳过片头」按钮。
    public var autoSkipIntro: Bool { didSet { save(autoSkipIntro, "player.autoSkipIntro") } }
    /// 剧集结束后倒计时自动播放下一集。
    public var autoPlayNext: Bool { didSet { save(autoPlayNext, "player.autoPlayNext") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        func raw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func codable<T: Codable>(_ key: String, _ fallback: T) -> T {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback
        }

        // 1.x 的第二内核为 MPV，已由 KSPlayer 取代：沿用用户「使用第二内核」的选择。
        engineMode = defaults.string(forKey: "player.engineMode") == "mpv" ? .ksPlayer : raw("player.engineMode", .auto)
        forwardBufferSeconds = value("player.forwardBufferSeconds", 0)
        decodeMode = raw("player.decodeMode", .hardware)
        softwareDecodeThreads = value("player.softwareDecodeThreads", 0)

        screenshotFormat = raw("player.screenshotFormat", .jpg)
        screenshotQuality = value("player.screenshotQuality", 0.8)
        screenshotSavesToPhotos = value("player.screenshotSavesToPhotos", false)

        rememberAudioTrack = value("player.rememberAudioTrack", true)
        preferredAudioLanguage = value("player.preferredAudioLanguage", "")
        enableAtmos = value("player.enableAtmos", true)
        nativeAudio = value("player.nativeAudio", true)

        rememberSubtitle = value("player.rememberSubtitle", true)
        preferredSubtitleLanguage = value("player.preferredSubtitleLanguage", "")
        recentSubtitleSearchLanguages = value("player.recentSubtitleSearchLanguages", [String]())
        subtitleScale = value("player.subtitle.scale", 1)
        subtitleBottomOffset = value("player.subtitle.bottomOffset", 0)

        pinchToZoom = value("player.gesture.pinchToZoom", true)
        rememberZoom = value("player.gesture.rememberZoom", false)
        savedZoomScale = value("player.gesture.savedZoomScale", 1)
        twoFingerPan = value("player.gesture.twoFingerPan", true)
        twoFingerTapReset = value("player.gesture.twoFingerTapReset", true)
        vrGyroscope = value("player.gesture.vrGyroscope", false)
        enableSwipeSeek = value("player.gesture.swipeSeek", true)
        enableBrightnessSwipe = value("player.gesture.brightness", true)
        enableVolumeSwipe = value("player.gesture.volume", true)
        enableSwipeSwitchMedia = value("player.gesture.switchMedia", false)
        longPressPlayPauseExits = value("player.gesture.longPressExit", false)
        leadingSpeed = value("player.gesture.leadingSpeed", 2)
        trailingSpeed = value("player.gesture.trailingSpeed", 2)
        singleTapCenter = raw("player.gesture.singleTapCenter", .toggleControls)
        singleTapSides = raw("player.gesture.singleTapSides", .toggleControls)
        doubleTapCenter = raw("player.gesture.doubleTapCenter", .playPause)
        doubleTapSides = raw("player.gesture.doubleTapSides", .seek)
        hapticLongPress = value("player.haptic.longPress", true)
        hapticSwipeSeek = value("player.haptic.swipeSeek", true)
        hapticScrubBar = value("player.haptic.scrubBar", true)
        keyHoldLeftSpeed = value("player.mac.keyHoldLeftSpeed", 0.5)
        keyHoldRightSpeed = value("player.mac.keyHoldRightSpeed", 2)
        digitKeysSetSpeed = value("player.mac.digitKeysSetSpeed", false)
        // 默认值与改动前的行为一致：左键单击播放 / 暂停、双击全屏；右键原本没有动作。
        leftClickAction = raw("player.mac.leftClick", .playPause)
        leftDoubleClickAction = raw("player.mac.leftDoubleClick", .fullScreen)
        rightClickAction = raw("player.mac.rightClick", .toggleControls)
        rightDoubleClickAction = raw("player.mac.rightDoubleClick", .fullScreen)

        osd = codable("player.osd", OSDOptions())
        buttons = codable("player.buttons", PlayerButtons())
        independentBrightness = value("player.independentBrightness", false)
        playerBrightness = value("player.brightness", 0.5)
        progressTimeMode = raw("player.progressTimeMode", .total)
        autoHideSeconds = value("player.autoHideSeconds", 5)
        orientationOnEnter = raw("player.orientationOnEnter", .unchanged)
        orientationOnSwitch = raw("player.orientationOnSwitch", .unchanged)
        landscapeSide = raw("player.landscapeSide", .auto)
        hintBeforeSkip = value("player.hint.skip", true)

        resumePlayback = value("player.resume", true)
        backgroundAudio = value("player.backgroundAudio", false)
        resumeOnForeground = value("player.resumeOnForeground", false)
        lockWhenPaused = value("player.lockWhenPaused", true)
        autoPictureInPicture = value("player.autoPiP", true)
        preciseSeek = value("player.preciseSeek", false)
        seekBackwardSeconds = value("player.seekBackwardSeconds", 10)
        seekForwardSeconds = value("player.seekForwardSeconds", 10)
        scrubPreview = raw("player.scrubPreview", .window)
        preloadNextPercent = value("player.preloadNextPercent", 0)
        autoSkipIntro = value("player.autoSkipIntro", false)
        autoPlayNext = value("player.autoPlayNext", true)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

// MARK: - 选项类型

public enum DecodeMode: String, CaseIterable, Sendable {
    case hardware, software

    public var title: String {
        switch self {
        case .hardware: "硬解码 (HW/GPU)"
        case .software: "软解码 (CPU)"
        }
    }
}

public enum ScreenshotFormat: String, CaseIterable, Sendable {
    case jpg, png, heic

    public var fileExtension: String { rawValue }
}

/// 单击 / 双击动作。「快退快进」「倍速」按点击位置在左 / 右半屏区分方向与倍速。
public enum PlayerTapAction: String, CaseIterable, Sendable {
    case toggleControls, playPause, seek, speed, none

    public var title: String {
        switch self {
        case .toggleControls: "显示/隐藏控制栏"
        case .playPause: "播放/暂停"
        case .seek: "快退快进"
        case .speed: "倍速播放"
        case .none: "无"
        }
    }
}

/// macOS 播放器画面上的鼠标点击动作。
public enum MouseClickAction: String, CaseIterable, Sendable {
    case playPause, fullScreen, toggleControls, none

    public var title: String {
        switch self {
        case .playPause: "播放/暂停"
        case .fullScreen: "全屏"
        case .toggleControls: "显示/隐藏控制栏"
        case .none: "无"
        }
    }
}

public enum ProgressTimeMode: String, CaseIterable, Sendable {
    case total, remaining

    public var title: String {
        switch self {
        case .total: "总时长"
        case .remaining: "剩余时长"
        }
    }
}

public enum PlayerOrientation: String, CaseIterable, Sendable {
    /// 保持当前方向。
    case unchanged
    case landscape
    case portrait
    /// 横向视频横屏、竖向视频竖屏。
    case followVideo

    public var title: String {
        switch self {
        case .unchanged: "无变化"
        case .landscape: "横屏"
        case .portrait: "竖屏"
        case .followVideo: "跟随视频"
        }
    }
}

/// 强制横屏时使用的方向。
public enum LandscapeSide: String, CaseIterable, Sendable {
    case auto, left, right

    public var title: String {
        switch self {
        case .auto: "自动"
        case .left: "向左"
        case .right: "向右"
        }
    }
}

public enum ScrubPreviewMode: String, CaseIterable, Sendable {
    /// 进度条上方小窗。
    case window
    /// 预览帧铺满画面。
    case fullscreen
    case off

    public var title: String {
        switch self {
        case .window: "小窗模式"
        case .fullscreen: "全屏模式"
        case .off: "关闭"
        }
    }
}

/// 屏幕角落的 OSD 信息。
public struct OSDOptions: Codable, Hashable, Sendable {
    public var clock = false
    public var frameRate = false
    public var networkSpeed = false
    public var playbackSpeed = false
    public var playbackTime = false
    public var cpuUsage = false
    public var battery = false
    public var textBackground = true
    public var textSize: OSDTextSize = .standard
    /// 贴近屏幕左右边缘（忽略安全区）。
    public var hugEdges = false
    public var landscapeOnly = false

    public init() {}

    public var hasContent: Bool {
        clock || frameRate || networkSpeed || playbackSpeed || playbackTime || cpuUsage || battery
    }
}

public enum OSDTextSize: String, Codable, CaseIterable, Sendable {
    case small, standard, large

    public var title: String {
        switch self {
        case .small: "小"
        case .standard: "标准"
        case .large: "大"
        }
    }
}

/// 控制栏中可隐藏的按钮。
public struct PlayerButtons: Codable, Hashable, Sendable {
    /// 中央快退 / 快进；默认显示，与 Android 版布局一致。
    public var seek = true
    public var switchMedia = true
    public var playPause = true
    public var zoom = true
    public var rotate = true
    public var pictureInPicture = true
    public var chapters = true
    public var speed = true
    public var cast = true
    public var screenshot = true

    public init() {}
}
