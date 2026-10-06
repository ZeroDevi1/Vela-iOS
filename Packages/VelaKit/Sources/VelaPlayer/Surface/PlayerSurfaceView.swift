import AVFoundation
import AVKit
import SwiftUI

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
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 渲染视图与画中画控制器的持有者。挂在 `PlayerController` 上，生命周期跟随播放会话而不是 SwiftUI 视图：
/// 画中画期间播放页被收起、视图离开窗口，`AVPlayerLayer` 与 `AVPictureInPictureController` 仍需存活，
/// 恢复时把同一个视图放回新的播放页。
@MainActor
final class PlayerSurfaceHost: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    let view = PlayerLayerView()
    /// 创建时的内核；内核替换后需要新建（AVPlayerLayer ↔ KSPlayer 视图）。
    let engineID: ObjectIdentifier
    private var pip: AVPictureInPictureController?
    private var lastToggleRequest: Int
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
            // 画中画依赖 AVPlayerLayer，只有系统内核支持。
            guard AVPictureInPictureController.isPictureInPictureSupported() else { break }
            let pip = AVPictureInPictureController(playerLayer: view.activeLayer)
            pip?.delegate = self
            #if os(iOS)
            // 退到后台时自动进入画中画（需要 Audio 后台模式），可在播放设置中关闭。
            pip?.canStartPictureInPictureAutomaticallyFromInline = controller.preferences.autoPictureInPicture
            #endif
            self.pip = pip
        case .view(let content):
            view.host(content)
        }
    }

    /// KSPlayer 的画中画控制器在起播后才创建（内容源为其 `AVSampleBufferDisplayLayer`），首次请求时再接管。
    private func adoptEnginePictureInPicture() {
        guard pip == nil, let engine = controller?.engine as? KSPlayerEngine,
              let controller = engine.pictureInPictureController else { return }
        controller.delegate = self
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = self.controller?.preferences.autoPictureInPicture ?? false
        #endif
        pip = controller
    }

    func handleToggle(_ request: Int) {
        guard request != lastToggleRequest else { return }
        lastToggleRequest = request
        adoptEnginePictureInPicture()
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    /// 后台继续播放声音：系统会暂停仍挂在可见图层上的视频播放器，切后台时先把播放器从图层上摘下，回前台再挂回。
    func setVideoDetached(_ detached: Bool) {
        guard let player, pip?.isPictureInPictureActive != true else { return }
        view.player = detached ? nil : player
    }

    func stopPictureInPicture() {
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
        controller?.isPictureInPictureActive = true
        controller?.onPictureInPictureStart?()
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
        guard let controller else { return }
        let restored = controller.isRestoringPictureInPicture
        controller.isPictureInPictureActive = false
        controller.isRestoringPictureInPicture = false
        controller.onPictureInPictureStop?(restored)
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
        (controller.engine as? KSPlayerEngine)?.setGravity(controller.videoGravity)
        controller.surfaceHost().handleToggle(controller.pictureInPictureToggleRequest)
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> PlayerLayerView { makeView() }
    public func updateUIView(_ view: PlayerLayerView, context: Context) { updateView(view) }
    #else
    public func makeNSView(context: Context) -> PlayerLayerView { makeView() }
    public func updateNSView(_ view: PlayerLayerView, context: Context) { updateView(view) }
    #endif
}
