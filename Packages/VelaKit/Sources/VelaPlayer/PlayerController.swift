import Foundation
import Observation
import VelaCore

/// 播放界面的状态机：控制层显隐、手势反馈、锁定、倍速与画面填充。内核相关状态从 `engine` 读取。
@MainActor
@Observable
public final class PlayerController {
    public enum VideoGravity: Sendable {
        case fit, fill
    }

    /// 手势过程中的居中提示。
    public enum HUD: Equatable, Sendable {
        case seek(target: TimeInterval, offset: TimeInterval)
        case brightness(Double)
        case volume(Double)
        case speed(Float)
        case skip(seconds: TimeInterval)
    }

    public let engine: any PlaybackEngine
    public private(set) var source: PlaybackSource?
    public var gestureSettings = PlayerGestureSettings()

    public private(set) var controlsVisible = true
    public private(set) var hud: HUD?
    public var isLocked = false
    public var videoGravity: VideoGravity = .fit
    /// 是否已进入画中画；由渲染表面回写。
    public var isPictureInPictureActive = false
    /// 画中画按钮触发器：值变化即请求切换，由渲染表面响应。
    public private(set) var pictureInPictureToggleRequest = 0

    /// 片头 / 片尾区段（按起点排序）。
    public var segments: [PlaybackSegment] = []
    /// 当前加载的文本字幕；nil 表示关闭或图形字幕已烧录进画面。
    public var subtitleTrack: SubtitleTrack?
    /// 「下一集」提示；非 nil 时显示卡片。
    public private(set) var upNext: UpNext?
    /// 用户点击「下一集」或倒计时结束时调用，由播放会话负责切换。
    @ObservationIgnored public var onPlayNext: (() -> Void)?
    @ObservationIgnored private var upNextTask: Task<Void, Never>?
    /// 用户关闭过的「下一集」提示不再自动弹出，直到切换条目。
    @ObservationIgnored private var upNextDismissed = false

    /// 拖动进度时的预览位置；非 nil 时进度条显示预览值，松手才执行 seek。
    public private(set) var scrubTime: TimeInterval?
    @ObservationIgnored private var scrubOrigin: TimeInterval = 0
    @ObservationIgnored private var rateBeforeHold: Float = 1
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// 菜单等弹出层打开期间固定显示控制层；自动隐藏会连带关闭菜单。
    @ObservationIgnored private var pinCount = 0
    @ObservationIgnored private var hudTask: Task<Void, Never>?

    /// 控制层无操作后自动隐藏的延迟（秒）。
    public static let controlsAutoHideDelay: Duration = .seconds(3)

    public init(engine: any PlaybackEngine = AVPlayerEngine()) {
        self.engine = engine
    }

    /// 加载新条目。`resetMetadata` 为 false 时保留片段与字幕（同一条目切换音轨 / 码流时使用）。
    public func load(_ source: PlaybackSource, resetMetadata: Bool = true) {
        self.source = source
        if resetMetadata {
            segments = []
            subtitleTrack = nil
            cancelUpNext()
            upNextDismissed = false
        }
        engine.load(source)
        scheduleAutoHide()
    }

    public func shutdown() {
        hideTask?.cancel()
        hudTask?.cancel()
        upNextTask?.cancel()
        engine.stop()
    }

    // MARK: - 片段

    /// 当前位置所在的片段（不含片尾：片尾由「下一集」提示处理）。
    public var activeSkippableSegment: PlaybackSegment? {
        let time = engine.currentTime
        return segments.first { $0.kind != .outro && $0.contains(time, duration: engine.duration) }
    }

    public var activeOutro: PlaybackSegment? {
        segments.first { $0.kind == .outro && $0.contains(engine.currentTime, duration: engine.duration) }
    }

    public func skip(_ segment: PlaybackSegment) {
        guard let end = segment.end else { return }
        Task { await engine.seek(to: end) }
    }

    // MARK: - 下一集

    public struct UpNext: Equatable, Sendable {
        public var title: String
        public var subtitle: String?
        public var imageURL: URL?
        /// 剩余秒数；nil 表示不自动播放，只显示按钮。
        public var countdown: Int?

        public init(title: String, subtitle: String?, imageURL: URL?, countdown: Int?) {
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.countdown = countdown
        }
    }

    /// 显示「下一集」提示。`autoplayAfter` 为倒计时秒数，nil 表示不自动播放。重复调用不会重置倒计时。
    public func presentUpNext(_ info: UpNext, autoplayAfter seconds: Int?) {
        guard upNext == nil, !upNextDismissed else { return }
        var info = info
        info.countdown = seconds
        upNext = info
        guard let seconds else { return }
        upNextTask = Task { [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                // 暂停时冻结倒计时，避免用户暂停查看片尾时被强制切走。
                while !self.isPlaying && self.engine.status != .ended {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { return }
                }
                self.upNext?.countdown = remaining
            }
            guard !Task.isCancelled, let self else { return }
            self.playNextNow()
        }
    }

    public func playNextNow() {
        cancelUpNext()
        onPlayNext?()
    }

    /// 用户关闭提示：本条目内不再自动弹出。
    public func dismissUpNext() {
        cancelUpNext()
        upNextDismissed = true
    }

    private func cancelUpNext() {
        upNextTask?.cancel()
        upNextTask = nil
        upNext = nil
    }

    // MARK: - 控制层

    public func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleAutoHide() }
    }

    /// 弹出菜单打开 / 关闭时调用，成对使用。
    public func pinControls(_ pinned: Bool) {
        pinCount = max(0, pinCount + (pinned ? 1 : -1))
        if pinCount == 0 { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    /// 用户与控制层交互时调用，重新计时自动隐藏。
    public func touchControls() {
        controlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.controlsAutoHideDelay)
            guard !Task.isCancelled, let self else { return }
            // 暂停或拖动时保持显示，方便用户继续操作。
            if self.engine.status == .playing && self.scrubTime == nil && self.pinCount == 0 {
                self.controlsVisible = false
            }
        }
    }

    // MARK: - 播放操作

    public var isPlaying: Bool {
        engine.status == .playing || engine.status == .buffering
    }

    public func togglePlayPause() {
        isPlaying ? engine.pause() : engine.play()
        touchControls()
    }

    public func skip(by seconds: TimeInterval) {
        let target = engine.currentTime + seconds
        Task { await engine.seek(to: target) }
        flashHUD(.skip(seconds: seconds))
    }

    public func skipBackward() { skip(by: -gestureSettings.seekBackwardSeconds) }
    public func skipForward() { skip(by: gestureSettings.seekForwardSeconds) }

    public func requestPictureInPictureToggle() {
        pictureInPictureToggleRequest &+= 1
    }

    // MARK: - 拖动进度

    public func beginScrub() {
        scrubOrigin = engine.currentTime
        scrubTime = scrubOrigin
        hideTask?.cancel()
    }

    /// 手势拖动：`offset` 为相对起点的秒数。
    public func updateScrub(offset: TimeInterval) {
        let upper = engine.duration > 0 ? engine.duration : .greatestFiniteMagnitude
        let target = min(max(0, scrubOrigin + offset), upper)
        scrubTime = target
        hud = .seek(target: target, offset: target - scrubOrigin)
    }

    /// 进度条直接拖动到绝对位置。
    public func updateScrub(to time: TimeInterval) {
        if scrubTime == nil { beginScrub() }
        scrubTime = time
    }

    public func endScrub(commit: Bool = true) {
        defer {
            scrubTime = nil
            hud = nil
            scheduleAutoHide()
        }
        guard commit, let target = scrubTime else { return }
        Task { await engine.seek(to: target) }
    }

    // MARK: - 长按倍速

    public func beginHoldSpeed() {
        rateBeforeHold = engine.rate
        engine.setRate(gestureSettings.holdSpeed)
        hud = .speed(gestureSettings.holdSpeed)
    }

    public func endHoldSpeed() {
        engine.setRate(rateBeforeHold)
        hud = nil
    }

    // MARK: - 亮度 / 音量反馈

    public func showLevel(_ hud: HUD) {
        hudTask?.cancel()
        self.hud = hud
    }

    public func clearHUD(after delay: Duration = .milliseconds(600)) {
        flashHUD(nil, delay: delay)
    }

    private func flashHUD(_ value: HUD?, delay: Duration = .milliseconds(700)) {
        hudTask?.cancel()
        if let value { hud = value }
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }
}
