import AVKit
import SwiftUI
import VelaPlayer

/// 播放控制层。可读性来自上下渐变遮罩，只有按钮本身使用 Liquid Glass，避免整片玻璃遮挡画面。
struct PlayerControlsView: View {
    let session: PlayerSession
    let onClose: () -> Void

    private var controller: PlayerController { session.controller }

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        ZStack {
            if controller.isLocked {
                lockedOverlay
            } else {
                fullControls
            }
        }
        .opacity(controller.controlsVisible ? 1 : 0)
        .allowsHitTesting(controller.controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: controller.controlsVisible)
    }

    private var fullControls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            transport
            Spacer()
            bottomBar
        }
        .background {
            VStack {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("关闭播放器")

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.source?.title ?? "").font(.headline).lineLimit(1)
                if let subtitle = controller.source?.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    TrackMenu(session: session)

                    #if os(iOS)
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                    #endif
                    Button {
                        controller.requestPictureInPictureToggle()
                    } label: {
                        Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("画中画")

                    moreMenu
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var moreMenu: some View {
        Menu {
            Picker("播放速度", selection: Binding(
                get: { controller.engine.rate },
                set: { controller.engine.setRate($0) }
            )) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "正常" : "\(speed.formatted())×").tag(speed)
                }
            }
            .pickerStyle(.menu)

            Picker("画面", selection: Binding(
                get: { controller.videoGravity },
                set: { controller.videoGravity = $0 }
            )) {
                Text("适应").tag(PlayerController.VideoGravity.fit)
                Text("填充").tag(PlayerController.VideoGravity.fill)
            }
            .pickerStyle(.menu)

            Color.clear.frame(width: 0, height: 0)
                .onAppear { controller.pinControls(true) }
                .onDisappear { controller.pinControls(false) }

            if controller.source?.vrLayout != nil {
                // VR 转平面渲染（Metal 反投影）在里程碑 M6 接入，这里先展示识别结果。
                Label("已识别 VR 片源", systemImage: "visionpro")
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("更多选项")
    }

    // MARK: - 中部

    private var transport: some View {
        GlassEffectContainer(spacing: 32) {
            HStack(spacing: 32) {
                transportButton("gobackward.\(Int(controller.gestureSettings.seekBackwardSeconds))", size: 26, label: "快退") {
                    controller.skipBackward()
                }
                transportButton(controller.isPlaying ? "pause.fill" : "play.fill", size: 38, label: controller.isPlaying ? "暂停" : "播放") {
                    controller.togglePlayPause()
                }
                transportButton("goforward.\(Int(controller.gestureSettings.seekForwardSeconds))", size: 26, label: "快进") {
                    controller.skipForward()
                }
            }
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 1.9, height: size * 1.9)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { controller.scrubTime ?? controller.engine.currentTime },
                    set: { controller.updateScrub(to: $0) }
                ),
                in: 0...max(controller.engine.duration, 1),
                onEditingChanged: { editing in
                    if editing { controller.beginScrub() } else { controller.endScrub() }
                }
            )
            .tint(.white)
            .disabled(controller.engine.duration <= 0)
            .accessibilityLabel("播放进度")

            HStack {
                Text(timeText(controller.scrubTime ?? controller.engine.currentTime))
                Spacer()
                Button {
                    controller.isLocked = true
                    controller.touchControls()
                } label: {
                    Image(systemName: "lock.open")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("锁定屏幕")
                Spacer()
                Text("-" + timeText(max(0, controller.engine.duration - (controller.scrubTime ?? controller.engine.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    controller.isLocked = false
                    controller.touchControls()
                } label: {
                    Image(systemName: "lock.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("解除锁定")
                Spacer()
            }
            .padding(24)
        }
        .foregroundStyle(.white)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }
}

/// 手势反馈：进度预览、亮度、音量、倍速、快进快退。
struct PlayerHUDView: View {
    let controller: PlayerController

    var body: some View {
        if let hud = controller.hud {
            Label(text(hud), systemImage: symbol(hud))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 72)
        }
    }

    private func text(_ hud: PlayerController.HUD) -> String {
        switch hud {
        case .seek(let target, let offset):
            let sign = offset >= 0 ? "+" : "-"
            return "\(format(target))  \(sign)\(format(abs(offset)))"
        case .brightness(let value), .volume(let value):
            return "\(Int(value * 100))%"
        case .speed(let rate):
            return "\(rate.formatted())× 倍速"
        case .skip(let seconds):
            return "\(seconds > 0 ? "+" : "")\(Int(seconds)) 秒"
        }
    }

    private func symbol(_ hud: PlayerController.HUD) -> String {
        switch hud {
        case .seek(_, let offset): offset >= 0 ? "forward.fill" : "backward.fill"
        case .brightness: "sun.max.fill"
        case .volume(let value): value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .speed: "forward.fill"
        case .skip(let seconds): seconds > 0 ? "goforward" : "gobackward"
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

#if os(iOS)
/// 系统 AirPlay 路由选择按钮。
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
