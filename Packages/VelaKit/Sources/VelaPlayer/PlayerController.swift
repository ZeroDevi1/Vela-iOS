import Foundation
import Observation
import VelaCore

/// 播放界面的状态机：控制层显隐、手势反馈、锁定、倍速与画面填充。内核相关状态从 `engine` 读取。
@MainActor
@Observable
public final class PlayerController {
    /// 画面比例：适应（留黑边）、填充（裁切）、拉伸（不保持比例）。
    public enum VideoGravity: Sendable, CaseIterable {
        case fit, fill, stretch

        public var title: String {
            switch self {
            case .fit: "适应"
            case .fill: "填充"
            case .stretch: "拉伸"
            }
        }

        public var symbol: String {
            switch self {
            case .fit: "rectangle.arrowtriangle.2.inward"
            case .fill: "rectangle.arrowtriangle.2.outward"
            case .stretch: "arrow.left.and.right.square"
            }
        }
    }

    /// 手势过程中的居中提示。拖动进度不走 HUD，由 `scrubTime` / `scrubOrigin` 驱动专门的预览指示。
    public enum HUD: Equatable, Sendable {
        case brightness(Double)
        case volume(Double)
        case speed(Float)
        case skip(seconds: TimeInterval)
        /// 一次性操作反馈，例如切换画面比例。
        case message(String, symbol: String)
    }

    /// 当前内核。会话可在起播前或失败重试时替换（系统 ↔ MPV），渲染表面按实例重建。
    public private(set) var engine: any PlaybackEngine
    public private(set) var source: PlaybackSource?
    public var gestureSettings = PlayerGestureSettings()

    public private(set) var controlsVisible = true
    public private(set) var hud: HUD?
    public var isLocked = false
    public var videoGravity: VideoGravity = .fit
    /// 画面顺时针旋转的 90° 次数（0...3），用于方向标记错误的片源。
    public private(set) var quarterTurns = 0
    /// 「VR 转平面」开启中（仅当片源识别为 VR 时可开启）。
    public private(set) var vrEnabled = false
    /// VR 视角；拖动 / 捏合时更新。
    public var vrState = VRViewState()
    /// 用户手动选择的排布（自动识别失败或识别有误时）；nil 使用自动识别结果。
    public private(set) var vrLayoutOverride: VRLayout?

    /// 实际使用的 VR 排布：手动选择优先，其次自动识别。
    public var effectiveVRLayout: VRLayout? { vrLayoutOverride ?? source?.vrLayout }
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
    /// 本次拖动开始时的位置，用于显示偏移量。
    public private(set) var scrubOrigin: TimeInterval = 0
    /// 拖动时的本地画面预览；预览源由播放会话按播放方式配置。
    public let scrubPreview = ScrubPreviewer()
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
            // 新条目：识别为 VR 时默认转平面（与 Android 版一致），可在菜单中关闭或改选排布。
            vrLayoutOverride = nil
            vrState = VRViewState()
            vrEnabled = source.vrLayout != nil && engine.kind == .avFoundation
        }
        if resetMetadata {
            segments = []
            subtitleTrack = nil
            cancelUpNext()
            upNextDismissed = false
        }
        engine.load(source)
        scheduleAutoHide()
    }

    /// 替换内核：停止旧内核并保留倍速设置。调用方随后需重新 `load`。
    public func replaceEngine(_ newEngine: any PlaybackEngine) {
        guard ObjectIdentifier(newEngine) != ObjectIdentifier(engine) else { return }
        let rate = engine.rate
        engine.stop()
        engine = newEngine
        newEngine.setRate(rate)
        // VR 与画中画依赖系统内核的画面输出。
        if newEngine.kind != .avFoundation {
            vrEnabled = false
            isPictureInPictureActive = false
        }
    }

    public func shutdown() {
        hideTask?.cancel()
        hudTask?.cancel()
        upNextTask?.cancel()
        scrubPreview.reset()
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
        /// 卡片标题，例如「下一集」「下一段」。
        public var heading: String

        public init(title: String, subtitle: String?, imageURL: URL?, countdown: Int?, heading: String = "下一集") {
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.countdown = countdown
            self.heading = heading
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

    /// 依次切换适应 → 填充 → 拉伸。
    public func cycleVideoGravity() {
        let all = VideoGravity.allCases
        let next = all[(all.firstIndex(of: videoGravity)! + 1) % all.count]
        videoGravity = next
        flashHUD(.message(next.title, symbol: next.symbol))
    }

    /// 画面顺时针旋转 90°。
    public func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        flashHUD(.message(quarterTurns == 0 ? "原始方向" : "旋转 \(quarterTurns * 90)°", symbol: "rotate.right"))
    }

    /// 开关「VR 转平面」；每次开启从正前方、默认视场角开始。
    public func toggleVR() {
        guard effectiveVRLayout != nil, engine.kind == .avFoundation else { return }
        vrEnabled.toggle()
        vrState = VRViewState()
        flashHUD(.message(vrEnabled ? "VR 转平面：拖动转视角，捏合缩放" : "已关闭 VR 转平面", symbol: "visionpro"), delay: .seconds(1.5))
    }

    /// 手动指定 VR 排布并开启转平面。
    public func selectVRLayout(_ layout: VRLayout) {
        guard engine.kind == .avFoundation else { return }
        vrLayoutOverride = layout
        vrState = VRViewState()
        vrEnabled = true
        flashHUD(.message("VR 转平面：\(layout.displayName)", symbol: "visionpro"), delay: .seconds(1.5))
    }

    /// 显示一次性提示（例如截图完成）。
    public func flash(_ message: String, symbol: String) {
        flashHUD(.message(message, symbol: symbol), delay: .seconds(1.2))
    }

    public func requestPictureInPictureToggle() {
        pictureInPictureToggleRequest &+= 1
    }

    // MARK: - 拖动进度

    /// 开始拖动：同时显示控制层，预览帧与时间指示都挂在控制层上。
    public func beginScrub() {
        scrubOrigin = engine.currentTime
        scrubTime = scrubOrigin
        controlsVisible = true
        hideTask?.cancel()
    }

    /// 手势拖动：`offset` 为相对起点的秒数。
    public func updateScrub(offset: TimeInterval) {
        let upper = engine.duration > 0 ? engine.duration : .greatestFiniteMagnitude
        let target = min(max(0, scrubOrigin + offset), upper)
        scrubTime = target
        scrubPreview.request(time: target)
    }

    /// 进度条直接拖动到绝对位置。
    public func updateScrub(to time: TimeInterval) {
        if scrubTime == nil { beginScrub() }
        scrubTime = time
        scrubPreview.request(time: time)
    }

    public func endScrub(commit: Bool = true) {
        defer {
            scrubTime = nil
            scrubPreview.clear()
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
