import SwiftUI
import VelaPlayer

#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit

/// iOS / iPadOS 手势层。用 UIKit 识别器实现，以便精确处理单击与双击的互斥、拖动方向锁定与长按倍速。
/// 判定规则见 `PlayerGestureModel`。
struct PlayerGestureLayer: UIViewRepresentable {
    let controller: PlayerController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.controller = controller
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var controller: PlayerController
        private weak var view: UIView?
        private let volume = SystemVolume()

        private var panKind: PlayerGestureModel.PanKind?
        private var panStart: CGPoint = .zero
        private var levelAtPanStart: Double = 0
        private var holdActive = false

        /// 屏幕边缘的系统手势区（控制中心、主屏幕指示条）内不触发拖动，单位 pt。
        private static let verticalEdgeExclusion: CGFloat = 48
        private static let horizontalEdgeExclusion: CGFloat = 24

        init(controller: PlayerController) {
            self.controller = controller
        }

        func install(on view: UIView) {
            self.view = view
            volume.attach(to: view)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.require(toFail: doubleTap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.45
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

            for recognizer in [doubleTap, singleTap, pan, longPress, pinch] {
                view.addGestureRecognizer(recognizer)
            }
        }

        private var isLandscape: Bool {
            guard let view else { return true }
            return view.bounds.width > view.bounds.height
        }

        // MARK: - 点击

        @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            controller.toggleControls()
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard !controller.isLocked, let view else { return }
            let zone = PlayerGestureModel.tapZone(
                x: recognizer.location(in: view).x,
                width: view.bounds.width,
                isLandscape: isLandscape
            )
            switch zone {
            case .leading: controller.skipBackward()
            case .trailing: controller.skipForward()
            case .center: controller.togglePlayPause()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // MARK: - 拖动

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard !controller.isLocked, !holdActive, let view, recognizer is UIPanGestureRecognizer else {
                return !(recognizer is UIPanGestureRecognizer)
            }
            let point = recognizer.location(in: view)
            let bounds = view.bounds
            return point.y > Self.verticalEdgeExclusion
                && point.y < bounds.height - Self.verticalEdgeExclusion
                && point.x > Self.horizontalEdgeExclusion
                && point.x < bounds.width - Self.horizontalEdgeExclusion
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            let translation = recognizer.translation(in: view)
            let size = view.bounds.size
            let settings = controller.gestureSettings

            switch recognizer.state {
            case .began:
                panKind = nil
                panStart = recognizer.location(in: view)
            case .changed:
                if panKind == nil {
                    guard let kind = PlayerGestureModel.panKind(
                        translation: CGSize(width: translation.x, height: translation.y),
                        startX: panStart.x,
                        width: size.width
                    ) else { return }
                    switch kind {
                    case .seek where settings.enableSwipeSeek:
                        controller.beginScrub()
                    case .brightness where settings.enableBrightnessVolume:
                        levelAtPanStart = Double(view.window?.windowScene?.screen.brightness ?? 0.5)
                    case .volume where settings.enableBrightnessVolume:
                        levelAtPanStart = Double(volume.current)
                    default:
                        recognizer.state = .cancelled
                        return
                    }
                    panKind = kind
                }
                switch panKind {
                case .seek:
                    controller.updateScrub(offset: PlayerGestureModel.seekOffset(
                        translationX: translation.x,
                        width: size.width,
                        duration: controller.engine.duration
                    ))
                case .brightness:
                    let value = clamp(levelAtPanStart + PlayerGestureModel.levelDelta(translationY: translation.y, height: size.height))
                    view.window?.windowScene?.screen.brightness = CGFloat(value)
                    controller.showLevel(.brightness(value))
                case .volume:
                    let value = clamp(levelAtPanStart + PlayerGestureModel.levelDelta(translationY: translation.y, height: size.height))
                    volume.set(Float(value))
                    controller.showLevel(.volume(value))
                case nil:
                    break
                }
            case .ended, .cancelled, .failed:
                if panKind == .seek {
                    controller.endScrub(commit: recognizer.state == .ended)
                } else if panKind != nil {
                    controller.clearHUD()
                }
                panKind = nil
            default:
                break
            }
        }

        // MARK: - 长按倍速

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard !controller.isLocked else { return }
            switch recognizer.state {
            case .began:
                guard panKind == nil, controller.isPlaying else { return }
                holdActive = true
                controller.beginHoldSpeed()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .ended, .cancelled, .failed:
                if holdActive {
                    holdActive = false
                    controller.endHoldSpeed()
                }
            default:
                break
            }
        }

        // MARK: - 捏合

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard !controller.isLocked, recognizer.state == .ended else { return }
            if recognizer.scale > 1 + PlayerGestureModel.pinchToggleThreshold {
                controller.videoGravity = .fill
            } else if recognizer.scale < 1 - PlayerGestureModel.pinchToggleThreshold {
                controller.videoGravity = .fit
            }
        }

        private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    }
}

/// 系统音量控制。iOS 没有公开的写音量接口，只能通过（隐藏的）`MPVolumeView` 内部滑块调节；
/// 视图保留在层级中可同时屏蔽系统音量 HUD。
@MainActor
private final class SystemVolume {
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    func attach(to view: UIView) {
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)
    }

    var current: Float { AVAudioSession.sharedInstance().outputVolume }

    func set(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = value
    }
}

#else

/// macOS：鼠标悬停唤出控制层，单击播放 / 暂停，双击全屏；键盘 空格 / ← → / F。
struct PlayerGestureLayer: View {
    let controller: PlayerController
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onContinuousHover { phase in
                if case .active = phase { controller.touchControls() }
            }
            .gesture(
                TapGesture(count: 2).onEnded { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .exclusively(before: TapGesture().onEnded { controller.togglePlayPause() })
            )
            .onKeyPress(.space) { controller.togglePlayPause(); return .handled }
            .onKeyPress(.leftArrow) { controller.skipBackward(); return .handled }
            .onKeyPress(.rightArrow) { controller.skipForward(); return .handled }
            .onKeyPress("f") { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
    }
}
#endif
