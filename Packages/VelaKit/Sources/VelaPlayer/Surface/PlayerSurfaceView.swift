import AVFoundation
import AVKit
import SwiftUI
import VelaCore

#if os(iOS)
public typealias PlayerPlatformView = UIView
public typealias PlayerPlatformViewRepresentable = UIViewRepresentable
#else
public typealias PlayerPlatformView = NSView
public typealias PlayerPlatformViewRepresentable = NSViewRepresentable
#endif

/// 承载 `AVPlayerLayer` 的原生视图。直接使用图层而不是 `AVPlayerViewController`，
/// 以便叠加自定义控制层与手势；画中画通过 `AVPictureInPictureController(playerLayer:)` 实现。
public final class PlayerLayerView: PlayerPlatformView {
    let playerLayer = AVPlayerLayer()

    #if os(iOS)
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var hostedLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    #endif

    var player: AVPlayer? {
        get { activeLayer.player }
        set { activeLayer.player = newValue }
    }

    /// KSPlayer 内核的视频视图容器，铺满视图；系统内核时为 nil。
    private(set) var hostedView: PlayerPlatformView?

    func host(_ view: PlayerPlatformView) {
        hostedView = view
        view.frame = bounds
        #if os(iOS)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.autoresizingMask = [.width, .height]
        #endif
        addSubview(view)
    }

    /// 带字幕画中画的样本缓冲区图层（见 `SubtitlePictureInPictureSource`）：放在最底层并铺满，平时为空。
    private var pictureInPictureLayer: CALayer?

    func installPictureInPictureLayer(_ layer: CALayer?) {
        pictureInPictureLayer?.removeFromSuperlayer()
        pictureInPictureLayer = layer
        guard let layer else { return }
        #if os(iOS)
        self.layer.insertSublayer(layer, at: 0)
        #else
        self.layer?.insertSublayer(layer, at: 0)
        #endif
        layer.frame = bounds
    }

    #if os(iOS)
    public override func layoutSubviews() {
        super.layoutSubviews()
        pictureInPictureLayer?.frame = bounds
    }
    #endif

    var activeLayer: AVPlayerLayer {
        #if os(iOS)
        hostedLayer
        #else
        playerLayer
        #endif
    }

    #if os(iOS)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    #else
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    public override func layout() {
        super.layout()
        playerLayer.frame = bounds
        pictureInPictureLayer?.frame = bounds
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 渲染视图与画中画控制器的持有者。挂在 `PlayerController` 上，生命周期跟随播放会话而不是 SwiftUI 视图：
/// 画中画期间播放页被收起、视图离开窗口，`AVPlayerLayer` 与 `AVPictureInPictureController` 仍需存活，
/// 恢复时把同一个视图放回新的播放页。
///
/// 画中画字幕：开着字幕时，系统内核改用 `SubtitlePictureInPictureSource`（样本缓冲区内容源，把字幕画进画面），
/// KSPlayer 在画中画期间通过送帧钩子叠加字幕；没有字幕时使用原生画中画，行为与之前一致。
@MainActor
final class PlayerSurfaceHost: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    let view = PlayerLayerView()
    /// 创建时的内核；内核替换后需要新建（AVPlayerLayer ↔ KSPlayer 视图）。
    let engineID: ObjectIdentifier
    /// 原生画中画：系统内核为 AVPlayerLayer，KSPlayer 为其 AVSampleBufferDisplayLayer。
    private var nativePictureInPicture: AVPictureInPictureController?
    /// 系统内核开着字幕时使用的画中画内容源。
    private var subtitleSource: SubtitlePictureInPictureSource?
    private let burner = SubtitleBurner()
    /// 画中画期间按 10 Hz 更新要画进画面的字幕文字。
    private var subtitleTimer: Timer?
    private var lastToggleRequest: Int
    private var isStartingPictureInPicture = false
    private weak var controller: PlayerController?
    private weak var player: AVPlayer?

    init(controller: PlayerController) {
        self.controller = controller
        engineID = ObjectIdentifier(controller.engine)
        lastToggleRequest = controller.pictureInPictureToggleRequest
        super.init()
        switch controller.engine.surface {
        case .avPlayer(let player):
            view.player = player
            self.player = player
            #if os(iOS)
            if let engine = controller.engine as? AVPlayerEngine {
                engine.canReplacePresentationPlayer = { [weak self] in
                    guard let self, let controller = self.controller else { return false }
                    return self.view.window?.windowScene?.activationState == .foregroundActive &&
                        self.view.player != nil && !controller.vrEnabled && !controller.isPictureInPictureActive &&
                        !self.isStartingPictureInPicture && self.activePictureInPicture == nil
                }
                engine.replacePresentationPlayer = { [weak self] player in
                    self?.player = player
                    self?.view.player = player
                    self?.subtitleSource?.setPlayer(player)
                }
            }
            #endif
            guard AVPictureInPictureController.isPictureInPictureSupported() else { break }
            let pip = AVPictureInPictureController(playerLayer: view.activeLayer)
            pip?.delegate = self
            nativePictureInPicture = pip
            refreshPictureInPictureSource(subtitlesActive: controller.hasActiveSubtitle)
        case .view(let content):
            view.host(content)
        }
    }

    private var allControllers: [AVPictureInPictureController] {
        [nativePictureInPicture, subtitleSource?.pictureInPicture].compactMap { $0 }
    }

    private var activePictureInPicture: AVPictureInPictureController? {
        allControllers.first { $0.isPictureInPictureActive }
    }

    /// KSPlayer 的画中画控制器在起播后才创建（内容源为其 `AVSampleBufferDisplayLayer`）：起播后或首次请求时接管。
    /// 须在切后台之前接管，否则「切到后台自动画中画」对 KSPlayer 不生效。
    func adoptEnginePictureInPicture() {
        guard nativePictureInPicture == nil, let engine = controller?.engine as? any EnginePictureInPictureProviding,
              let pip = engine.pictureInPictureController else { return }
        pip.delegate = self
        nativePictureInPicture = pip
        updateAutomaticPictureInPicture()
    }

    /// 系统内核：开着字幕时由带字幕的内容源负责画中画（含切后台自动进入），否则交给原生画中画。画中画进行中不切换。
    func refreshPictureInPictureSource(subtitlesActive: Bool) {
        #if os(macOS)
        // macOS 不走系统画中画（改用置顶小窗，见 `PlayerController.isMiniWindow`），不创建带字幕的样本缓冲区内容源：
        // 系统把这类小窗的画面按源图层在播放器窗口中的尺寸摆放、不随小窗缩放（实测 macOS 27.2：小窗约 400×300，
        // 画面 960×720，只露出放大的一角）。系统修复后可用 `VELA_DEBUG_DUMP_PIP=1` 复查再恢复。
        let subtitlesActive = false
        #endif
        guard let player, AVPictureInPictureController.isPictureInPictureSupported(),
              let controller, activePictureInPicture == nil else { return }
        if subtitlesActive, subtitleSource == nil {
            let source = SubtitlePictureInPictureSource(player: player, controller: controller, burner: burner)
            source.pictureInPicture?.delegate = self
            source.onPossibleChange = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.refreshPictureInPictureSource(subtitlesActive: controller.hasActiveSubtitle)
            }
            view.installPictureInPictureLayer(source.displayLayer)
            subtitleSource = source
        } else if !subtitlesActive, let source = subtitleSource {
            source.invalidate()
            view.installPictureInPictureLayer(nil)
            subtitleSource = nil
        }
        updateAutomaticPictureInPicture()
    }

    /// 「切后台自动画中画」只在开启设置且正在播放时允许：用户已暂停时切后台不应弹出小窗。
    /// 播放状态变化时由 `PlayerSurface` 的更新再次调用。只让一个控制器负责自动进入：
    /// 系统内核带字幕的内容源可用时用它，否则（含尚未就绪）用原生画中画。
    func updateAutomaticPictureInPicture() {
        #if os(iOS)
        guard let controller else { return }
        let auto = controller.preferences.autoPictureInPicture && controller.isPlaying
        let useSubtitleSource = subtitleSource?.isPossible == true
        nativePictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = auto && !useSubtitleSource
        subtitleSource?.pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = auto && useSubtitleSource
        #endif
    }

    func handleToggle(_ request: Int) {
        guard request != lastToggleRequest else { return }
        lastToggleRequest = request
        if let controller, !controller.isPictureInPictureActive {
            #if os(macOS)
            // macOS 只有系统内核的原生图层画中画可用（KSPlayer 的样本缓冲区画中画不随小窗缩放）。
            let supported = controller.engine.supportsLayerPictureInPicture
            #else
            let supported = controller.engine.supportsPictureInPicture
            #endif
            guard supported else {
                controller.showMessage("\(controller.engine.kind.title) 内核暂不支持系统画中画", symbol: "pip", duration: .seconds(3))
                return
            }
        }
        adoptEnginePictureInPicture()
        if let active = activePictureInPicture {
            active.stopPictureInPicture()
        } else if let subtitleSource, subtitleSource.isPossible, subtitleSource.start() {
            // 带字幕的小窗已启动。
        } else {
            // 带字幕的内容源不可用时回退到原生画中画（无字幕），保证画中画始终能打开。
            nativePictureInPicture?.startPictureInPicture()
        }
    }

    /// 后台继续播放声音：系统会暂停仍挂在可见图层上的视频播放器，切后台时先把播放器从图层上摘下，回前台再挂回。
    func setVideoDetached(_ detached: Bool) {
        guard let player, activePictureInPicture == nil else { return }
        view.player = detached ? nil : player
    }

    func stopPictureInPicture() {
        activePictureInPicture?.stopPictureInPicture()
    }

    /// 播放状态变化时让带字幕的小窗刷新播放 / 暂停按钮（原生画中画由系统自行跟踪）。
    func invalidatePlaybackState() {
        subtitleSource?.invalidatePlaybackState()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pip: AVPictureInPictureController) {
        isStartingPictureInPicture = true
        #if os(macOS)
        selectManifestSubtitleForPictureInPicture()
        #endif
    }

    #if os(macOS)
    /// macOS 系统画中画只渲染播放器自己的字幕轨：开着字幕时选中码流字幕组中的对应轨，结束时取消（平时由应用绘制）。
    private func selectManifestSubtitleForPictureInPicture() {
        guard let controller, controller.hasActiveSubtitle else { return }
        let track = controller.manifestSubtitle?()
        Task { [weak controller] in
            guard let controller, let engine = controller.engine as? any ManifestSubtitleSelecting else { return }
            let selected = if let track { await engine.selectManifestSubtitle(ordinal: track.ordinal, name: track.name) } else { false }
            Log.player.info("系统画中画字幕：\(track.map { "#\($0.ordinal) \($0.name ?? "-")" } ?? "无对应字幕轨", privacy: .public) selected=\(selected)")
            if !selected {
                controller.showMessage("该字幕无法在系统画中画中显示，可改用「画中画」小窗（⌥⌘P）", symbol: "captions.bubble", duration: .seconds(5))
            }
        }
    }
    #endif

    func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
        isStartingPictureInPicture = false
        if pip === subtitleSource?.pictureInPicture {
            subtitleSource?.didStart()
            // 画中画期间 AVPlayer 只输出到视频输出：仍挂在 AVPlayerLayer 上的播放器切到后台会被系统暂停。
            view.player = nil
        }
        if let engine = controller?.engine as? any PictureInPictureSubtitleBurning, controller?.hasActiveSubtitle == true {
            engine.setPictureInPictureSubtitles(burner)
        }
        startSubtitleUpdates()
        #if DEBUG
        if let engine = controller?.engine as? KSPlayerEngine { Log.player.debug("画中画开始：\(engine.pictureInPictureDiagnostics(), privacy: .public)") }
        #if os(macOS)
        if ProcessInfo.processInfo.environment["VELA_DEBUG_DUMP_PIP"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                DebugPictureInPictureLayout.dump()
            }
        }
        #endif
        #endif
        controller?.isPictureInPictureActive = true
        controller?.onPictureInPictureStart?()
    }

    func pictureInPictureController(
        _ pip: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isStartingPictureInPicture = false
    }

    func pictureInPictureController(
        _ pip: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let controller, let restore = controller.onPictureInPictureRestore else {
            completionHandler(true)
            return
        }
        controller.isRestoringPictureInPicture = true
        restore(completionHandler)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
        stopSubtitleUpdates()
        #if os(macOS)
        if let engine = controller?.engine as? any ManifestSubtitleSelecting {
            Task { _ = await engine.selectManifestSubtitle(ordinal: nil, name: nil) }
        }
        #endif
        if pip === subtitleSource?.pictureInPicture {
            subtitleSource?.didStop()
            view.player = player
        }
        (controller?.engine as? any PictureInPictureSubtitleBurning)?.setPictureInPictureSubtitles(nil)
        guard let controller else { return }
        let restored = controller.isRestoringPictureInPicture
        controller.isPictureInPictureActive = false
        controller.isRestoringPictureInPicture = false
        controller.onPictureInPictureStop?(restored)
        refreshPictureInPictureSource(subtitlesActive: controller.hasActiveSubtitle)
    }

    private func startSubtitleUpdates() {
        stopSubtitleUpdates()
        burner.setText(controller?.currentSubtitleText())
        // 主线程计时器在画中画（应用处于后台）时仍会触发；10 Hz 足以跟上字幕切换。
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.burner.setText(self.controller?.currentSubtitleText())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        subtitleTimer = timer
    }

    private func stopSubtitleUpdates() {
        subtitleTimer?.invalidate()
        subtitleTimer = nil
        burner.setText(nil)
    }

    /// 播放会话结束时释放画中画资源。
    func invalidate() {
        stopSubtitleUpdates()
        for pip in allControllers { pip.delegate = nil }
        subtitleSource?.invalidate()
        subtitleSource = nil
        nativePictureInPicture = nil
        controller = nil
    }
}

/// SwiftUI 包装：把会话持有的渲染视图放进当前界面，同步填充模式、响应画中画请求。
public struct PlayerSurface: PlayerPlatformViewRepresentable {
    let controller: PlayerController

    public init(controller: PlayerController) {
        self.controller = controller
    }

    @MainActor
    private func makeView() -> PlayerLayerView {
        controller.surfaceHost().view
    }

    @MainActor
    private func updateView(_ view: PlayerLayerView) {
        view.activeLayer.videoGravity = switch controller.videoGravity {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
        let host = controller.surfaceHost()
        (controller.engine as? any VideoGravityAdjustable)?.setGravity(controller.videoGravity)
        if let engine = controller.engine as? any EnginePictureInPictureProviding {
            // 读取状态以便起播（readyToPlay）后再次更新，此时内核的画中画控制器已创建，可以接管。
            if engine.status != .loading { host.adoptEnginePictureInPicture() }
        }
        // 读取字幕状态：开 / 关字幕时切换系统内核的画中画内容源。
        host.refreshPictureInPictureSource(subtitlesActive: controller.hasActiveSubtitle)
        // 读取播放状态：暂停 / 播放后刷新带字幕小窗的按钮，并同步是否允许切后台自动画中画。
        _ = controller.isPlaying
        host.updateAutomaticPictureInPicture()
        host.invalidatePlaybackState()
        host.handleToggle(controller.pictureInPictureToggleRequest)
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> PlayerLayerView { makeView() }
    public func updateUIView(_ view: PlayerLayerView, context: Context) { updateView(view) }
    #else
    public func makeNSView(context: Context) -> PlayerLayerView { makeView() }
    public func updateNSView(_ view: PlayerLayerView, context: Context) { updateView(view) }
    #endif
}
