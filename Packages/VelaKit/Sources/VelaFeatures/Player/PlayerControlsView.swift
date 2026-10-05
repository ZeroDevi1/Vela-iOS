import AVKit
import SwiftUI
import VelaDesignSystem
import VelaPlayer

/// 播放控制层（参考 SenPlayer 布局）。图标直接压在上下渐变遮罩上，不加玻璃底，尽量少遮挡画面。
///
/// - 顶部：标题；关闭、AirPlay、画面比例、旋转 | 画中画、章节、截图、倍速
/// - 拖动时顶部居中：当前 / 总时长、迷你进度条、偏移量；预览帧浮在进度条上方并跟随拖动位置
/// - 底部次级行：播放信息 | 音轨、字幕、更多
/// - 进度行：当前时间、进度条（含缓冲）、总时长
/// - 传输行：锁定 | 上一集（电影为快退）、播放 / 暂停、下一集（电影为快进） | 剧集
struct PlayerControlsView: View {
    let session: PlayerSession
    @Binding var panel: PlayerPanel?
    let onClose: () -> Void

    private var controller: PlayerController { session.controller }
    /// 「自定义播放器按钮」。
    private var buttons: PlayerButtons { controller.preferences.buttons }

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        let visible = controller.controlsVisible && panel == nil
        // 隐藏时移出视图树而不是只设透明度：否则进度与时间仍按 4 Hz 刷新，整层阴影也随之重新离屏渲染。
        ZStack {
            if visible {
                Group {
                    if controller.isLocked {
                        lockedOverlay
                    } else {
                        fullControls
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
    }

    private var fullControls: some View {
        VStack(spacing: 0) {
            topBar
            ScrubTimeIndicator(controller: controller)
                .padding(.top, 12)
            Spacer(minLength: 0)
            bottomArea
        }
        .background {
            VStack {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 180)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3)
    }

    // MARK: - 顶部

    private var topBar: some View {
        VStack(spacing: 6) {
            title
            HStack(spacing: 4) {
                iconButton("xmark", label: "关闭播放器", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if buttons.cast {
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                }
                if buttons.zoom {
                    iconButton(controller.videoGravity.symbol, label: "画面比例：\(controller.videoGravity.title)") {
                        controller.cycleVideoGravity()
                        controller.touchControls()
                    }
                }
                #if os(iOS)
                if buttons.rotate, OrientationController.isSupported {
                    iconButton("arrow.trianglehead.2.clockwise.rotate.90", label: "横竖屏切换") {
                        OrientationController.toggle()
                        controller.touchControls()
                    }
                }
                #endif

                Spacer(minLength: 0)

                // 画中画依赖系统内核的 AVPlayerLayer。
                if buttons.pictureInPicture, controller.engine.kind == .avFoundation {
                    iconButton(controller.isPictureInPictureActive ? "pip.exit" : "pip.enter", label: "画中画") {
                        controller.requestPictureInPictureToggle()
                    }
                }
                if buttons.chapters, session.chapters.count > 1 {
                    iconButton("book", label: "章节") { open(.chapters) }
                }
                if buttons.screenshot {
                    iconButton("camera", label: "截图") { session.captureScreenshot() }
                }
                if buttons.speed {
                    speedMenu
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var title: some View {
        let parts = [controller.source?.title, controller.source?.subtitle].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 24)
    }

    private var speedMenu: some View {
        Menu {
            Picker("播放速度", selection: Binding(
                get: { controller.engine.rate },
                set: { controller.engine.setRate($0) }
            )) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "正常" : "\(speed.formatted())×").tag(speed)
                }
            }
            pinWhileOpen
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title3)
                .overlay(alignment: .bottomTrailing) {
                    if controller.engine.rate != 1 {
                        Text("\(controller.engine.rate.formatted())×")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .offset(x: 10, y: 8)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("播放速度")
        .accessibilityValue("\(controller.engine.rate.formatted())×")
    }

    // MARK: - 底部

    private var bottomArea: some View {
        VStack(spacing: 6) {
            secondaryRow
            scrubberRow
            transportRow
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var secondaryRow: some View {
        HStack(spacing: 4) {
            iconButton("info.circle", label: "播放信息") { open(.info) }
            Spacer(minLength: 0)
            if !session.audioOptions.isEmpty {
                let isMuted = controller.engine.isMuted
                iconButton(isMuted ? "speaker.slash.circle" : "waveform.circle", label: isMuted ? "音轨（已静音）" : "音轨") { open(.audio) }
                    .disabled(session.isSwitchingStream)
            }
            iconButton(session.selectedSubtitleIndex == nil ? "captions.bubble" : "captions.bubble.fill", label: "字幕") {
                open(.subtitle)
            }
            .disabled(session.isSwitchingStream)
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("截图", systemImage: "camera") { session.captureScreenshot() }
            Button("画面旋转 90°", systemImage: "rotate.right") { controller.rotateClockwise() }
            Picker("画面比例", selection: Binding(
                get: { controller.videoGravity },
                set: { controller.videoGravity = $0 }
            )) {
                ForEach(PlayerController.VideoGravity.allCases, id: \.self) { gravity in
                    Label(gravity.title, systemImage: gravity.symbol).tag(gravity)
                }
            }
            if controller.engine.kind == .avFoundation {
                // 任何片源都可手动选择排布：文件名不规范时自动识别会漏掉。
                Menu {
                    if controller.effectiveVRLayout != nil {
                        Toggle(isOn: Binding(get: { controller.vrEnabled }, set: { _ in controller.toggleVR() })) {
                            Text("开启")
                        }
                    }
                    Section(controller.source?.vrLayout.map { "自动识别：\($0.displayName)" } ?? "未自动识别，手动选择排布") {
                        ForEach(VRLayoutParser.manualOptions, id: \.self) { layout in
                            Button {
                                controller.selectVRLayout(layout)
                            } label: {
                                if controller.vrEnabled, controller.effectiveVRLayout == layout {
                                    Label(layout.displayName, systemImage: "checkmark")
                                } else {
                                    Text(layout.displayName)
                                }
                            }
                        }
                    }
                } label: {
                    Label("VR 转平面", systemImage: "visionpro")
                }
            } else {
                // MPV 没有可供反投影的画面输出：提供切回系统内核（从当前位置继续）。
                Button("VR 转平面（切换到系统内核）", systemImage: "visionpro") { session.switchToSystemEngineForVR() }
            }
            pinWhileOpen
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("更多选项")
    }

    /// 独立子视图：进度每 0.25 秒变化一次，只让这一行刷新，不牵动整个控制层。
    private var scrubberRow: some View {
        ScrubberRow(controller: controller)
    }

    private var transportRow: some View {
        // 剧集与多段文件（CD1 / CD2）都提供上一个 / 下一个。
        let isEpisode = session.item?.kind == .episode || session.partPosition != nil
        return HStack {
            HStack {
                iconButton("lock.open", label: "锁定屏幕", size: 22) {
                    controller.isLocked = true
                    controller.touchControls()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 28) {
                if isEpisode, buttons.switchMedia {
                    iconButton("backward.end.fill", label: session.partPosition == nil ? "上一集" : "上一段", size: 24) { session.playPreviousEpisode() }
                        .disabled(session.previousEpisode == nil)
                }
                if buttons.seek {
                    iconButton("gobackward.\(controller.preferences.seekBackwardSeconds)", label: "快退", size: 24) {
                        controller.skipBackward()
                    }
                }
                if buttons.playPause {
                    playPauseButton
                }
                if buttons.seek {
                    iconButton("goforward.\(controller.preferences.seekForwardSeconds)", label: "快进", size: 24) {
                        controller.skipForward()
                    }
                }
                if isEpisode, buttons.switchMedia {
                    iconButton("forward.end.fill", label: session.partPosition == nil ? "下一集" : "下一段", size: 24) { controller.playNextNow() }
                        .disabled(session.nextEpisode == nil)
                        // 下一集已预加载：服务器已开始准备，切换会更快。
                        .overlay(alignment: .topTrailing) {
                            if session.isNextPreloaded {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.yellow)
                                    .offset(x: -4, y: 6)
                                    .accessibilityLabel("已预加载")
                            }
                        }
                }
            }
            .fixedSize()

            HStack {
                Spacer(minLength: 0)
                if !session.seasonEpisodes.isEmpty {
                    iconButton("list.bullet", label: "剧集列表", size: 22) { open(.episodes) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 播放 / 暂停；开启「长按播放暂停键退出播放器」时长按关闭播放器。
    private var playPauseButton: some View {
        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 34, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 56, height: 56)
            .contentShape(.rect)
            .onTapGesture { controller.togglePlayPause() }
            .onLongPressGesture(minimumDuration: 0.6) {
                if controller.preferences.longPressPlayPauseExits { onClose() }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(controller.isPlaying ? "暂停" : "播放")
            .accessibilityAction { controller.togglePlayPause() }
    }

    /// 无底色的图标按钮，点击区域固定 44pt。
    private func iconButton(_ symbol: String, label: String, size: CGFloat = 20, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    /// 菜单打开期间固定显示控制层（自动隐藏会连带关闭菜单）。
    private var pinWhileOpen: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { controller.pinControls(true) }
            .onDisappear { controller.pinControls(false) }
    }

    private func open(_ target: PlayerPanel) {
        withAnimation(.snappy) { panel = target }
    }
}

// MARK: - 进度条

/// 进度行：当前时间、进度条、总时长。
private struct ScrubberRow: View {
    let controller: PlayerController

    var body: some View {
        let position = controller.scrubTime ?? controller.engine.currentTime
        HStack(spacing: 12) {
            Text(PlayerTime.format(position))
                .frame(minWidth: 44, alignment: .leading)
            PlayerScrubber(controller: controller)
            // 「进度条时间模式」：总时长或剩余时长；点按切换。
            Text(trailingTime(position: position))
                .frame(minWidth: 44, alignment: .trailing)
                .contentShape(.rect)
                .onTapGesture {
                    let preferences = controller.preferences
                    preferences.progressTimeMode = preferences.progressTimeMode == .total ? .remaining : .total
                    controller.touchControls()
                }
        }
        .font(.footnote.monospacedDigit())
    }

    private func trailingTime(position: TimeInterval) -> String {
        let duration = controller.engine.duration
        guard controller.preferences.progressTimeMode == .remaining, duration > 0 else { return PlayerTime.format(duration) }
        return "-" + PlayerTime.format(max(0, duration - position))
    }
}

/// 细进度条：未播放 / 已缓冲 / 已播放三段，拖动时放大滑块，并在上方浮出跟随位置的预览帧。
/// 不用系统 `Slider`：需要缓冲段，并且预览帧要按滑块的横向位置定位。
private struct PlayerScrubber: View {
    let controller: PlayerController

    /// 预览帧底边距进度条顶部的距离：越过次级按钮行，避免遮挡手指附近的按钮。
    private static let previewLift: CGFloat = 56
    private static let height: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = controller.engine.duration
            let position = controller.scrubTime ?? controller.engine.currentTime
            let progress = fraction(position, of: duration)
            let buffered = fraction(controller.engine.bufferedTime, of: duration)
            let isScrubbing = controller.scrubTime != nil

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.45)).frame(width: width * buffered)
                Capsule().fill(.white).frame(width: width * progress)
            }
            .frame(height: isScrubbing ? 6 : 4)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 18 : 12, height: isScrubbing ? 18 : 12)
                    .offset(x: width * progress - (isScrubbing ? 9 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .overlay(alignment: .bottomLeading) {
                if isScrubbing, controller.scrubPreview.isEnabled, controller.preferences.scrubPreview == .window {
                    let size = previewSize(trackWidth: width)
                    ScrubPreviewFrame(previewer: controller.scrubPreview, size: size)
                        .offset(
                            x: min(max(0, width * progress - size.width / 2), max(0, width - size.width)),
                            y: -(Self.height + Self.previewLift)
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if controller.scrubTime == nil { controller.beginScrub() }
                        controller.updateScrub(to: duration * fraction(value.location.x, of: width))
                    }
                    .onEnded { _ in
                        if controller.scrubTime != nil { controller.endScrub() }
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isScrubbing)
            .sensoryFeedback(trigger: isScrubbing) { _, _ in
                controller.preferences.hapticScrubBar ? .impact(weight: .light) : nil
            }
        }
        .frame(height: Self.height)
        .disabled(controller.engine.duration <= 0)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(PlayerTime.format(controller.engine.currentTime)) / \(PlayerTime.format(controller.engine.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skipForward()
            case .decrement: controller.skipBackward()
            @unknown default: break
            }
        }
    }

    /// 竖屏手机进度条较窄，预览帧相应缩小。
    private func previewSize(trackWidth: CGFloat) -> CGSize {
        let width: CGFloat = trackWidth < 400 ? 176 : 240
        return CGSize(width: width, height: width * 9 / 16)
    }

    private func fraction(_ value: Double, of total: Double) -> Double {
        guard total > 0, value.isFinite else { return 0 }
        return min(1, max(0, value / total))
    }
}

/// 预览帧：白色描边圆角框；帧未解码出来时显示加载指示。
private struct ScrubPreviewFrame: View {
    let previewer: ScrubPreviewer
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            if let image = previewer.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.5), radius: 8)
    }
}

/// 拖动时在顶部居中显示：「当前 / 总时长」、迷你进度条、偏移量。不拖动时不占位。
private struct ScrubTimeIndicator: View {
    let controller: PlayerController

    var body: some View {
        if let time = controller.scrubTime {
            let duration = controller.engine.duration
            let offset = time - controller.scrubOrigin
            VStack(spacing: 4) {
                Text("\(PlayerTime.format(time)) / \(PlayerTime.format(duration))")
                    .font(.title2.weight(.semibold).monospacedDigit())
                if duration > 0 {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 180, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: 180 * min(1, max(0, time / duration)), height: 3)
                        }
                }
                Text((offset >= 0 ? "+ " : "- ") + PlayerTime.format(abs(offset)))
                    .font(.headline.monospacedDigit())
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// 手势反馈：亮度、音量、倍速、快进快退与一次性提示。
struct PlayerHUDView: View {
    let controller: PlayerController

    var body: some View {
        if let hud = controller.hud, controller.scrubTime == nil {
            Label(text(hud), systemImage: symbol(hud))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 96)
        }
    }

    private func text(_ hud: PlayerController.HUD) -> String {
        switch hud {
        case .brightness(let value), .volume(let value):
            "\(Int(value * 100))%"
        case .speed(let rate):
            "\(rate.formatted())× 倍速"
        case .skip(let seconds):
            "\(seconds > 0 ? "+" : "")\(Int(seconds)) 秒"
        case .message(let text, _):
            text
        }
    }

    private func symbol(_ hud: PlayerController.HUD) -> String {
        switch hud {
        case .brightness: "sun.max.fill"
        case .volume(let value): value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .speed: "forward.fill"
        case .skip(let seconds): seconds > 0 ? "goforward" : "gobackward"
        case .message(_, let symbol): symbol
        }
    }
}

/// 系统 AirPlay 路由选择按钮。
#if os(iOS)
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
