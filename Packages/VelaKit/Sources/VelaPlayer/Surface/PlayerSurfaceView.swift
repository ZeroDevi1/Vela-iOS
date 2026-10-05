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

    /// MPV 内核的渲染图层，铺满视图；系统内核时为 nil。
    private(set) var metalLayer: CAMetalLayer?

    func host(_ layer: CAMetalLayer) {
        metalLayer = layer
        #if os(iOS)
        self.layer.addSublayer(layer)
        #else
        self.layer?.addSublayer(layer)
        #endif
        layoutMetalLayer()
    }

    private func layoutMetalLayer() {
        guard let metalLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        #if os(iOS)
        metalLayer.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        #else
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        #endif
        CATransaction.commit()
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

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutMetalLayer()
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
        layoutMetalLayer()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// SwiftUI 包装：渲染画面、同步填充模式、响应画中画请求。
public struct PlayerSurface: PlayerPlatformViewRepresentable {
    let controller: PlayerController

    public init(controller: PlayerController) {
        self.controller = controller
    }

    /// 画中画回调在主线程触发，按主 actor 隔离处理。
    @MainActor
    public final class Coordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
        var pip: AVPictureInPictureController?
        var lastToggleRequest = 0
        weak var controller: PlayerController?

        func attach(to layer: AVPlayerLayer, controller: PlayerController) {
            self.controller = controller
            guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
            let pip = AVPictureInPictureController(playerLayer: layer)
            pip?.delegate = self
            #if os(iOS)
            // 退到后台时自动进入画中画（需要 Audio 后台模式）。
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
            self.pip = pip
        }

        func handleToggle(_ request: Int) {
            guard request != lastToggleRequest else { return }
            lastToggleRequest = request
            guard let pip else { return }
            pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
        }

        public func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
            controller?.isPictureInPictureActive = true
        }

        public func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
            controller?.isPictureInPictureActive = false
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    private func makeView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        switch controller.engine.surface {
        case .avPlayer(let player):
            view.player = player
            // 画中画依赖 AVPlayerLayer，只有系统内核支持。
            context.coordinator.lastToggleRequest = controller.pictureInPictureToggleRequest
            context.coordinator.attach(to: view.activeLayer, controller: controller)
        case .metalLayer(let layer):
            view.host(layer)
        }
        return view
    }

    @MainActor
    private func updateView(_ view: PlayerLayerView, context: Context) {
        view.activeLayer.videoGravity = switch controller.videoGravity {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
        (controller.engine as? MPVEngine)?.setGravity(fill: controller.videoGravity == .fill, stretch: controller.videoGravity == .stretch)
        context.coordinator.handleToggle(controller.pictureInPictureToggleRequest)
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> PlayerLayerView { makeView(context: context) }
    public func updateUIView(_ view: PlayerLayerView, context: Context) { updateView(view, context: context) }
    #else
    public func makeNSView(context: Context) -> PlayerLayerView { makeView(context: context) }
    public func updateNSView(_ view: PlayerLayerView, context: Context) { updateView(view, context: context) }
    #endif
}
