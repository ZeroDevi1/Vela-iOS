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

    /// 当前内核。会话可在起播前或失败重试时替换（系统 ↔ KSPlayer），渲染表面按实例重建。
    public private(set) var engine: any PlaybackEngine
    public private(set) var source: PlaybackSource?
    /// 播放偏好；会话起播时换成应用共享的实例，设置页的修改即时生效。
    public var preferences = PlayerPreferences()

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
    /// VR 转平面拿不到画面时的原因（由渲染器诊断），界面据此提示而不是只显示黑屏；正常出画面时为 nil。
    public var vrIssue: String?
    /// 用户手动选择的排布（自动识别失败或识别有误时）；nil 使用自动识别结果。
    public private(set) var vrLayoutOverride: VRLayout?

    /// 实际使用的 VR 排布：手动选择优先，其次自动识别。
    public var effectiveVRLayout: VRLayout? { vrLayoutOverride ?? source?.vrLayout }
    /// 是否已进入画中画；由渲染表面回写。
    public var isPictureInPictureActive = false
    /// 画中画按钮触发器：值变化即请求切换，由渲染表面响应。
    public private(set) var pictureInPictureToggleRequest = 0
    /// 正在从画中画恢复界面（系统已调用恢复回调、尚未结束画中画）。
    public internal(set) var isRestoringPictureInPicture = false

    /// 画中画事件，由上层决定播放页的去留：开始时可收起播放页（会话继续由上层持有）；
    /// 恢复时重新呈现播放页，完成后调用传入的回调；结束时参数表示是否经由「恢复」结束（否则为用户关闭小窗）。
    @ObservationIgnored public var onPictureInPictureStart: (() -> Void)?
    @ObservationIgnored public var onPictureInPictureRestore: ((@escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored public var onPictureInPictureStop: ((_ restored: Bool) -> Void)?
    /// 渲染视图与画中画控制器；随会话存活，播放页收起再呈现时复用。
    @ObservationIgnored private var host: PlayerSurfaceHost?

    /// 片头 / 片尾区段（按起点排序）。
    public var segments: [PlaybackSegment] = []
    /// 当前加载的文本字幕；nil 表示关闭或图形字幕已烧录进画面。
    public var subtitleTrack: SubtitleTrack?
    /// 「下一集」提示；非 nil 时显示卡片。
    public private(set) var upNext: UpNext?
    /// 用户点击「下一集」或倒计时结束时调用，由播放会话负责切换。
    @ObservationIgnored public var onPlayNext: (() -> Void)?
    /// 中间竖直下滑切换到上一集时调用。
    @ObservationIgnored public var onPlayPrevious: (() -> Void)?
    /// 长按播放 / 暂停按钮退出播放器时调用。
    @ObservationIgnored public var onRequestClose: (() -> Void)?

    /// 画面缩放倍率（1 为原始大小）与缩放后的平移量（pt）；双指手势调整。
    public var zoomScale: CGFloat = 1
    public var zoomOffset: CGSize = .zero
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
            vrIssue = nil
            vrEnabled = source.vrLayout != nil
            zoomScale = preferences.rememberZoom ? CGFloat(preferences.savedZoomScale) : 1
            zoomOffset = .zero
        }
        if resetMetadata {
            segments = []
            subtitleTrack = nil
            cancelUpNext()
            upNextDismissed = false
        }
        engine.preciseSeeking = preferences.preciseSeek
        engine.load(source)
        scheduleAutoHide()
    }

    /// 替换内核：停止旧内核并保留倍速设置。调用方随后需重新 `load`。
    public func replaceEngine(_ newEngine: any PlaybackEngine) {
        guard ObjectIdentifier(newEngine) != ObjectIdentifier(engine) else { return }
        let rate = engine.rate
        let isMuted = engine.isMuted
        engine.stop()
        engine = newEngine
        newEngine.setRate(rate)
        newEngine.setMuted(isMuted)
        // 画中画绑定在旧内核的渲染图层上，随旧内核结束。
        isPictureInPictureActive = false
    }

    /// 当前内核的渲染宿主；内核替换后重建。
    func surfaceHost() -> PlayerSurfaceHost {
        if let host, host.engineID == ObjectIdentifier(engine) { return host }
        host?.stopPictureInPicture()
        let host = PlayerSurfaceHost(controller: self)
        self.host = host
        return host
    }

    public func stopPictureInPicture() {
        host?.stopPictureInPicture()
    }

    /// 切后台继续播放声音时摘下画面（见 `PlayerSurfaceHost.setVideoDetached`）。
    public func setVideoDetached(_ detached: Bool) {
        host?.setVideoDetached(detached)
    }

    public func shutdown() {
        host?.stopPictureInPicture()
        host = nil
        onPictureInPictureStart = nil
        onPictureInPictureRestore = nil
        onPictureInPictureStop = nil
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
        let seconds = preferences.autoHideSeconds
        guard seconds > 0 else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
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

    public func skipBackward() { skip(by: -TimeInterval(preferences.seekBackwardSeconds)) }
    public func skipForward() { skip(by: TimeInterval(preferences.seekForwardSeconds)) }

    /// 执行单击 / 双击动作；`zone` 决定快退快进的方向与倍速使用左 / 右半屏的设置。
    public func perform(_ action: PlayerTapAction, zone: PlayerGestureModel.TapZone) {
        switch action {
        case .toggleControls:
            toggleControls()
        case .playPause:
            togglePlayPause()
        case .seek:
            switch zone {
            case .leading: skipBackward()
            case .trailing: skipForward()
            case .center: togglePlayPause()
            }
        case .speed:
            toggleSpeedBoost(leading: zone == .leading)
        case .none:
            break
        }
    }

    /// 双击倍速：再次双击恢复原速。
    public func toggleSpeedBoost(leading: Bool) {
        let boost = leading ? preferences.leadingSpeed : preferences.trailingSpeed
        if engine.rate == boost {
            engine.setRate(rateBeforeHold == boost ? 1 : rateBeforeHold)
            flashHUD(.speed(engine.rate))
        } else {
            rateBeforeHold = engine.rate
            engine.setRate(boost)
            flashHUD(.speed(boost))
        }
    }

    // MARK: - 画面缩放

    /// 双指捏合：按增量缩放，限制在 `PlayerGestureModel.zoomRange`。
    public func zoom(by factor: CGFloat) {
        let range = PlayerGestureModel.zoomRange
        zoomScale = min(max(zoomScale * factor, range.lowerBound), range.upperBound)
        if zoomScale == 1 { zoomOffset = .zero }
        if preferences.rememberZoom { preferences.savedZoomScale = Double(zoomScale) }
    }

    /// 双指拖动：缩放后移动画面。
    public func pan(by delta: CGSize) {
        guard zoomScale > 1 else { return }
        zoomOffset = CGSize(width: zoomOffset.width + delta.width, height: zoomOffset.height + delta.height)
    }

    public func resetZoom() {
        zoomScale = 1
        zoomOffset = .zero
        if preferences.rememberZoom { preferences.savedZoomScale = 1 }
        flashHUD(.message("画面已重置", symbol: "arrow.up.left.and.down.right.magnifyingglass"))
    }

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
        guard effectiveVRLayout != nil else { return }
        vrEnabled.toggle()
        vrState = VRViewState()
        flashHUD(.message(vrEnabled ? "VR 转平面：拖动转视角，捏合缩放" : "已关闭 VR 转平面", symbol: "visionpro"), delay: .seconds(1.5))
    }

    /// 手动指定 VR 排布并开启转平面。
    public func selectVRLayout(_ layout: VRLayout) {
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
        if preferences.scrubPreview != .off { scrubPreview.request(time: target) }
    }

    /// 进度条直接拖动到绝对位置。
    public func updateScrub(to time: TimeInterval) {
        if scrubTime == nil { beginScrub() }
        scrubTime = time
        if preferences.scrubPreview != .off { scrubPreview.request(time: time) }
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

    /// - Parameter leading: 长按位置在左半屏时用左侧倍速设置，否则用右侧。
    public func beginHoldSpeed(leading: Bool) {
        let speed = leading ? preferences.leadingSpeed : preferences.trailingSpeed
        rateBeforeHold = engine.rate
        engine.setRate(speed)
        hud = .speed(speed)
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

    /// 短暂显示一条提示（如内核切换原因）。
    public func showMessage(_ text: String, symbol: String, duration: Duration = .seconds(2.5)) {
        flashHUD(.message(text, symbol: symbol), delay: duration)
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
