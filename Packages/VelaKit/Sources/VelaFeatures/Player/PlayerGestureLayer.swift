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
        /// VR 模式下拖动转视角：记录上一次的平移量，按增量更新。
        private var lastVRTranslation: CGPoint = .zero

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
            pinch.delegate = self
            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2

            for recognizer in [doubleTap, singleTap, pan, longPress, pinch, twoFingerPan, twoFingerTap] {
                view.addGestureRecognizer(recognizer)
            }
        }

        private var preferences: PlayerPreferences { controller.preferences }

        private var isLandscape: Bool {
            guard let view else { return true }
            return view.bounds.width > view.bounds.height
        }

        private func zone(of recognizer: UIGestureRecognizer) -> PlayerGestureModel.TapZone {
            guard let view else { return .center }
            return PlayerGestureModel.tapZone(x: recognizer.location(in: view).x, width: view.bounds.width, isLandscape: isLandscape)
        }

        // MARK: - 点击

        @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            // 锁定时单击只唤出解锁按钮。
            guard !controller.isLocked else {
                controller.toggleControls()
                return
            }
            let zone = zone(of: recognizer)
            controller.perform(zone == .center ? preferences.singleTapCenter : preferences.singleTapSides, zone: zone)
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard !controller.isLocked else { return }
            let zone = zone(of: recognizer)
            let action = zone == .center ? preferences.doubleTapCenter : preferences.doubleTapSides
            guard action != .none else { return }
            controller.perform(action, zone: zone)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // MARK: - 拖动

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            guard !controller.isLocked, !holdActive, let view else { return false }
            // 双指拖动只在画面放大后用于移动画面。
            if pan.minimumNumberOfTouches == 2 { return preferences.twoFingerPan && controller.zoomScale > 1 }
            let point = recognizer.location(in: view)
            let bounds = view.bounds
            return point.y > Self.verticalEdgeExclusion
                && point.y < bounds.height - Self.verticalEdgeExclusion
                && point.x > Self.horizontalEdgeExclusion
                && point.x < bounds.width - Self.horizontalEdgeExclusion
        }

        /// 捏合与双指拖动可同时进行（边放大边移动）。
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair = [recognizer, other]
            return pair.contains { $0 is UIPinchGestureRecognizer }
                && pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            // VR 转平面：拖动只转视角，不调进度 / 亮度 / 音量。
            if controller.vrEnabled, let layout = controller.effectiveVRLayout {
                let translation = recognizer.translation(in: view)
                if recognizer.state == .began { lastVRTranslation = .zero }
                let delta = CGSize(width: translation.x - lastVRTranslation.x, height: translation.y - lastVRTranslation.y)
                lastVRTranslation = translation
                controller.vrState.drag(by: delta, viewSize: view.bounds.size, layout: layout)
                return
            }
            let translation = recognizer.translation(in: view)
            let size = view.bounds.size

            switch recognizer.state {
            case .began:
                panKind = nil
                panStart = recognizer.location(in: view)
            case .changed:
                if panKind == nil {
                    guard let kind = PlayerGestureModel.panKind(
                        translation: CGSize(width: translation.x, height: translation.y),
                        startX: panStart.x,
                        width: size.width,
                        switchMediaZone: preferences.enableSwipeSwitchMedia
                    ) else { return }
                    switch kind {
                    case .seek where preferences.enableSwipeSeek:
                        controller.beginScrub()
                        if preferences.hapticSwipeSeek { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    case .brightness where preferences.enableBrightnessSwipe:
                        levelAtPanStart = Double(view.window?.windowScene?.screen.brightness ?? 0.5)
                    case .volume where preferences.enableVolumeSwipe:
                        levelAtPanStart = Double(volume.current)
                    case .switchMedia:
                        break
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
                    PlayerBrightness.didAdjust(value, preferences: preferences)
                    controller.showLevel(.brightness(value))
                case .volume:
                    let value = clamp(levelAtPanStart + PlayerGestureModel.levelDelta(translationY: translation.y, height: size.height))
                    volume.set(Float(value))
                    controller.showLevel(.volume(value))
                case .switchMedia, nil:
                    break
                }
            case .ended, .cancelled, .failed:
                switch panKind {
                case .seek:
                    controller.endScrub(commit: recognizer.state == .ended)
                    if preferences.hapticSwipeSeek, recognizer.state == .ended { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                case .switchMedia where recognizer.state == .ended:
                    // 上滑下一集、下滑上一集。
                    if translation.y < -PlayerGestureModel.switchMediaDistance {
                        controller.playNextNow()
                    } else if translation.y > PlayerGestureModel.switchMediaDistance {
                        controller.onPlayPrevious?()
                    }
                case nil, .switchMedia:
                    break
                default:
                    controller.clearHUD()
                }
                panKind = nil
            default:
                break
            }
        }

        // MARK: - 长按倍速

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard !controller.isLocked, let view else { return }
            switch recognizer.state {
            case .began:
                guard panKind == nil, controller.isPlaying else { return }
                holdActive = true
                controller.beginHoldSpeed(leading: recognizer.location(in: view).x < view.bounds.width / 2)
                if preferences.hapticLongPress { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            case .ended, .cancelled, .failed:
                if holdActive {
                    holdActive = false
                    controller.endHoldSpeed()
                }
            default:
                break
            }
        }

        // MARK: - 双指

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard !controller.isLocked else { return }
            // VR 转平面：捏合连续调整视场角。
            if controller.vrEnabled {
                controller.vrState.zoom(by: Double(recognizer.scale))
                recognizer.scale = 1
                return
            }
            if preferences.pinchToZoom {
                controller.zoom(by: recognizer.scale)
                recognizer.scale = 1
                return
            }
            guard recognizer.state == .ended else { return }
            if recognizer.scale > 1 + PlayerGestureModel.pinchToggleThreshold {
                controller.videoGravity = .fill
            } else if recognizer.scale < 1 - PlayerGestureModel.pinchToggleThreshold {
                controller.videoGravity = .fit
            }
        }

        @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, !controller.vrEnabled else { return }
            let translation = recognizer.translation(in: view)
            controller.pan(by: CGSize(width: translation.x, height: translation.y))
            recognizer.setTranslation(.zero, in: view)
        }

        @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard !controller.isLocked, !controller.vrEnabled, preferences.twoFingerTapReset else { return }
            controller.resetZoom()
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
    /// VR 拖动的上一次平移量与捏合的上一次倍率，按增量更新视角。
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1

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
            .simultaneousGesture(vrDrag, including: controller.vrEnabled ? .all : .none)
            .simultaneousGesture(vrMagnify, including: controller.vrEnabled ? .all : .none)
            .onKeyPress(.space) { controller.togglePlayPause(); return .handled }
            .onKeyPress(.leftArrow) { controller.skipBackward(); return .handled }
            .onKeyPress(.rightArrow) { controller.skipForward(); return .handled }
            .onKeyPress("f") { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
    }

    /// VR 转平面：鼠标拖动转视角。
    private var vrDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let layout = controller.effectiveVRLayout, let size = NSApp.keyWindow?.contentView?.bounds.size else { return }
                let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                controller.vrState.drag(by: delta, viewSize: size, layout: layout)
            }
            .onEnded { _ in lastDrag = .zero }
    }

    /// VR 转平面：触控板捏合缩放。
    private var vrMagnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                controller.vrState.zoom(by: value.magnification / lastMagnification)
                lastMagnification = value.magnification
            }
            .onEnded { _ in lastMagnification = 1 }
    }
}
#endif
