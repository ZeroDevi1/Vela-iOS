import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VelaCore
import VelaDesignSystem
import VelaPlayer

/// 播放控制层。布局与 Android 版（`ControlsOverlay`）一致，保留 iOS 的 SF Symbols、原生菜单、AirPlay 与系统画中画：
///
/// - 顶部：返回、（横屏）剧集 Logo | 内核标签、AirPlay、画中画、媒体信息、画面比例、旋转、章节、更多
/// - 左侧居中：截图、锁定；右侧居中：倍速（＋ / 当前值 / －）
/// - 中央：快退、播放 / 暂停（缓冲时转圈）、快进
/// - 底部：上一集 / 下一集、标题块（剧名 · 单集 · HDR 标记，点按看单集信息）；时间 + 按章节分段的进度条；
///   剧集 / 音轨 / 字幕按钮（横屏在进度条右侧，竖屏居中在下方）
///
/// 按钮用半透明圆底而不是玻璃材质：玻璃需要对下方逐帧变化的视频实时模糊，十余个按钮叠在 4K 画面上会持续占用 GPU。
/// 拖动进度时只保留进度行，其余控件淡出，让预览帧与时间成为唯一焦点（与 Android 版相同）。
struct PlayerControlsView: View {
    let session: PlayerSession
    @Binding var panel: PlayerPanel?
    let onClose: () -> Void
    /// 「更多 → 添加本地字幕」的文件选择器。
    @State private var isImportingSubtitle = false

    private var controller: PlayerController { session.controller }
    /// 「自定义播放器按钮」。
    private var buttons: PlayerButtons { controller.preferences.buttons }

    private static let speedPresets: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    /// 倍速 ＋ / － 的步长与范围，与 Android 版一致。
    private static let speedStep: Float = 0.25
    private static let speedRange: ClosedRange<Float> = 0.25...4

    var body: some View {
        // iOS 面板打开时隐藏控制层；macOS 面板是锚在按钮上的 popover，控制层保持显示。
        #if os(macOS)
        let visible = controller.controlsVisible
        #else
        let visible = controller.controlsVisible && panel == nil
        #endif
        // 隐藏时移出视图树而不是只设透明度：否则进度与时间仍按 4 Hz 刷新，整层也随之重新合成。
        ZStack {
            if visible {
                GeometryReader { proxy in
                    let landscape = proxy.size.width > proxy.size.height
                    if controller.isLocked {
                        lockedOverlay(landscape: landscape)
                    } else {
                        #if os(macOS)
                        macControls
                        #else
                        fullControls(landscape: landscape)
                        #endif
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
        .fileImporter(isPresented: $isImportingSubtitle, allowedContentTypes: Self.subtitleTypes) { result in
            switch result {
            case .success(let url): session.loadLocalSubtitle(from: url)
            case .failure(let error): controller.showMessage("无法打开文件：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: .seconds(3))
            }
        }
    }

    /// 本地字幕可选的文件类型。SRT / ASS 没有系统声明的类型，按扩展名生成动态类型；部分文件管理器把它们标成纯文本。
    private static let subtitleTypes: [UTType] =
        ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) } + [.plainText]

    private var hasFailed: Bool {
        if case .failed = controller.engine.status { return true }
        return false
    }

    private func fullControls(landscape: Bool) -> some View {
        let chrome: Double = controller.scrubTime == nil ? 1 : 0
        let edge: CGFloat = landscape ? 20 : 12
        return ZStack {
            VStack(spacing: 0) {
                topSection(landscape: landscape)
                    .opacity(chrome)
                    .overlay(alignment: .top) { ScrubTimeIndicator(controller: controller) }
                Spacer(minLength: 0)
                bottomSection(landscape: landscape, chrome: chrome)
            }

            // 播放出错时中央显示错误与重试按钮，不再叠放传输控件与两侧按钮。
            if !hasFailed {
                HStack {
                    leftColumn(landscape: landscape)
                    Spacer(minLength: 0)
                    if buttons.speed { speedControl(landscape: landscape) }
                }
                .padding(.horizontal, edge)
                .opacity(chrome)

                transportControls(landscape: landscape)
                    .opacity(chrome)
            }
        }
        .padding(.horizontal, landscape ? 8 : 0)
        .background { scrims(landscape: landscape) }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: chrome)
    }

    /// 上下渐变遮罩：保证白色控件在亮画面上的对比度。
    private func scrims(landscape: Bool) -> some View {
        VStack {
            LinearGradient(colors: [.black.opacity(0.66), .black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: landscape ? 150 : 200)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.3), .black.opacity(0.66)], startPoint: .top, endPoint: .bottom)
                .frame(height: landscape ? 200 : 300)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 顶部

    private func topSection(landscape: Bool) -> some View {
        #if os(macOS)
        let size = Self.barButtonSize
        #else
        let size: CGFloat = landscape ? 48 : 40
        #endif
        return HStack(spacing: landscape ? 10 : 4) {
            #if os(macOS)
            // Esc 由菜单栏「播放」处理：全屏时先退出全屏。
            circleButton("xmark", label: "关闭播放器", size: size, action: onClose)
            #else
            circleButton("chevron.backward", label: "关闭播放器", size: size, action: onClose)
                .keyboardShortcut(.cancelAction)
            #endif
            if landscape, let logo = session.logoURL {
                CachedImage(url: logo, contentMode: .fit) { EmptyView() }
                    .frame(maxWidth: 200, maxHeight: 48, alignment: .leading)
                    .padding(.leading, 6)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            if session.canSwitchEngine {
                engineBadge(size: size)
            }
            if buttons.cast {
                AirPlayButton()
                    .frame(width: size, height: size)
                    .background(Circle().fill(Self.buttonFill))
                    .accessibilityLabel("AirPlay")
            }
            if buttons.pictureInPicture {
                circleButton(controller.isPictureInPictureActive ? "pip.exit" : "pip.enter", label: "画中画", size: size) {
                    controller.requestPictureInPictureToggle()
                }
            }
            circleButton("info.circle", label: "媒体信息", size: size) { open(.info) }
                .playerPanelPopover([.info], panel: $panel, session: session, arrowEdge: .bottom)
            if buttons.zoom {
                circleButton(controller.videoGravity.symbol, label: "画面比例：\(controller.videoGravity.title)", size: size) {
                    controller.cycleVideoGravity()
                    controller.touchControls()
                }
            }
            #if os(iOS)
            if buttons.rotate, OrientationController.isSupported {
                circleButton("arrow.trianglehead.2.clockwise.rotate.90", label: "横竖屏切换", size: size) {
                    OrientationController.toggle()
                    controller.touchControls()
                }
            }
            #endif
            if buttons.chapters, session.chapters.count > 1 {
                circleButton("book", label: "章节", size: size) { open(.chapters) }
                    .playerPanelPopover([.chapters], panel: $panel, session: session, arrowEdge: .bottom)
            }
            moreMenu(size: size)
                .playerPanelPopover([.subtitleStyle, .subtitleDelay], panel: $panel, session: session, arrowEdge: .bottom)
        }
        .padding(.horizontal, landscape ? 12 : 12)
        .padding(.top, landscape ? 8 : 4)
    }

    /// 当前内核的文字标签（对应 Android 顶栏的解码模式标签），点按选择其他内核并从当前位置继续。
    private func engineBadge(size: CGFloat) -> some View {
        let current = controller.engine.kind
        return Menu {
            engineChoices
        } label: {
            Text(Self.badgeText(current))
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .frame(minWidth: size, minHeight: size)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(!session.canSwitchEngine)
        .accessibilityLabel("当前\(current.title)内核，点按切换内核")
    }

    /// 四个内核的单选列表（当前内核打勾），选择后从当前位置用新内核重新起播。
    @ViewBuilder
    private var engineChoices: some View {
        ForEach(PlaybackEngineKind.allCases, id: \.self) { kind in
            Toggle(isOn: Binding(
                get: { controller.engine.kind == kind },
                set: { if $0 { session.switchEngine(to: kind) } }
            )) { Text(kind.title) }
        }
    }

    private static func badgeText(_ kind: PlaybackEngineKind) -> String {
        switch kind {
        case .avFoundation: "AV"
        case .ksPlayer: "KS"
        }
    }

    private func moreMenu(size: CGFloat) -> some View {
        Menu {
            if session.canSwitchEngine {
                Menu("切换内核", systemImage: "arrow.left.arrow.right") { engineChoices }
            }
            sleepTimerMenu
            Button("媒体信息", systemImage: "info.circle") { open(.info) }
            Picker("调整画面尺寸", systemImage: "aspectratio", selection: Binding(
                get: { controller.videoGravity },
                set: { controller.videoGravity = $0 }
            )) {
                ForEach(PlayerController.VideoGravity.allCases, id: \.self) { gravity in
                    Label(gravity.title, systemImage: gravity.symbol).tag(gravity)
                }
            }
            Button("画面旋转 90°", systemImage: "rotate.right") { controller.rotateClockwise() }
            Divider()
            Button("添加本地字幕", systemImage: "plus") { isImportingSubtitle = true }
            Button("字幕缩放与位置", systemImage: "textformat.size") { open(.subtitleStyle) }
            Button("字幕时间偏移", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") { open(.subtitleDelay) }
            Divider()
            vrMenu
            pinWhileOpen
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.45, weight: .semibold))
        }
        .menuIndicator(.hidden)
        .buttonStyle(OverlayCircleButtonStyle(size: size))
        .accessibilityLabel("更多选项")
    }

    /// 定时关闭（与 Android 版相同的预设）：到时暂停播放。
    private var sleepTimerMenu: some View {
        Menu {
            Button {
                session.setSleepTimer(minutes: nil)
            } label: {
                if session.sleepDeadline == nil { Label("关闭", systemImage: "checkmark") } else { Text("关闭") }
            }
            ForEach(PlayerSession.sleepTimerPresets, id: \.self) { minutes in
                Button("\(minutes) 分钟") { session.setSleepTimer(minutes: minutes) }
            }
        } label: {
            if let deadline = session.sleepDeadline {
                let minutes = max(1, Int((deadline.timeIntervalSinceNow / 60).rounded(.up)))
                Label("定时关闭（剩余 \(minutes) 分钟）", systemImage: "moon.zzz.fill")
            } else {
                Label("定时关闭", systemImage: "moon.zzz")
            }
        }
    }

    /// VR 转平面：两种内核都支持。任何片源都可手动选择排布（文件名不规范时自动识别会漏掉）。
    private var vrMenu: some View {
        Menu {
            if controller.effectiveVRLayout != nil {
                Toggle(isOn: Binding(get: { controller.vrEnabled }, set: { _ in controller.toggleVR() })) {
                    Text("开启")
                }
                if VRMotionTracker.isAvailable {
                    Toggle(isOn: Binding(get: { controller.preferences.vrGyroscope }, set: { controller.preferences.vrGyroscope = $0 })) {
                        Text("重力感应")
                    }
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
            if session.canSaveVRLayoutTag {
                Button("保存排布到服务器标签", systemImage: "tag") { session.saveVRLayoutTag() }
            }
        } label: {
            Label("VR 转平面", systemImage: "visionpro")
        }
    }

    #if os(macOS)
    // MARK: - macOS 控制层

    /// macOS：不用触屏的中央大按钮与两侧按钮列（锁屏、竖排倍速），改为常见桌面播放器的结构——
    /// 顶栏（关闭、内核、画中画、信息、更多）+ 底部工具条（标题、进度、播放控制与各面板入口、倍速、全屏）。
    /// 键盘操作由菜单栏「播放」菜单提供（`PlayerCommands`）。
    private var macControls: some View {
        let chrome: Double = controller.scrubTime == nil ? 1 : 0
        let hasNavigation = (session.item?.kind == .episode || session.partPosition != nil) && buttons.switchMedia
        return VStack(spacing: 0) {
            topSection(landscape: true)
                .opacity(chrome)
                .overlay(alignment: .top) { ScrubTimeIndicator(controller: controller) }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                titleBlock.opacity(chrome)
                HStack(spacing: 10) {
                    PlaybackTimeLabel(controller: controller)
                    PlayerScrubber(controller: controller, chapterStarts: session.chapters.map(\.chapter.start))
                }
                HStack(spacing: 8) {
                    if hasNavigation {
                        circleButton("backward.end.fill", label: "上一集", size: Self.barButtonSize) { session.playPreviousEpisode() }
                            .disabled(session.previousEpisode == nil)
                    }
                    if buttons.seek {
                        circleButton(Self.seekSymbol("gobackward", controller.preferences.seekBackwardSeconds), label: "快退", size: Self.barButtonSize) {
                            controller.skipBackward()
                        }
                    }
                    macPlayPauseButton
                    if buttons.seek {
                        circleButton(Self.seekSymbol("goforward", controller.preferences.seekForwardSeconds), label: "快进", size: Self.barButtonSize) {
                            controller.skipForward()
                        }
                    }
                    if hasNavigation {
                        circleButton("forward.end.fill", label: "下一集", size: Self.barButtonSize) { controller.playNextNow() }
                            .disabled(session.nextEpisode == nil)
                    }
                    Spacer(minLength: 0)
                    if buttons.screenshot {
                        circleButton("camera", label: "截图", size: Self.barButtonSize) { session.captureScreenshot() }
                    }
                    bottomActions
                    if buttons.speed { macSpeedMenu }
                    circleButton("arrow.up.left.and.arrow.down.right", label: "全屏", size: Self.barButtonSize) {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                }
                .opacity(chrome)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .background { scrims(landscape: true) }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: chrome)
    }

    /// 底栏的播放 / 暂停；缓冲时显示小号转圈。
    @ViewBuilder
    private var macPlayPauseButton: some View {
        let status = controller.engine.status
        if status == .buffering || status == .loading || session.isSwitchingStream {
            ProgressView().controlSize(.small).tint(.white)
                .frame(width: 40, height: 40)
        } else {
            circleButton(controller.isPlaying ? "pause.fill" : "play.fill", label: controller.isPlaying ? "暂停" : "播放", size: 40, iconScale: 0.5) {
                controller.togglePlayPause()
            }
        }
    }

    /// 倍速：当前倍速文字，点按选择预设（± 微调在「播放」菜单）。
    private var macSpeedMenu: some View {
        let rate = controller.engine.rate
        return Menu {
            Picker("播放速度", selection: Binding(
                get: { controller.engine.rate },
                set: { controller.engine.setRate($0) }
            )) {
                ForEach(Self.speedPresets, id: \.self) { speed in
                    Text(speed == 1 ? "正常" : "\(speed.formatted())×").tag(speed)
                }
            }
            pinWhileOpen
        } label: {
            Text("\(rate.formatted())×")
                .font(.callout.weight(rate == 1 ? .medium : .bold).monospacedDigit())
                .padding(.horizontal, 8)
                .frame(minWidth: Self.barButtonSize, minHeight: Self.barButtonSize)
                .background(Capsule().fill(Self.buttonFill))
                .contentShape(.capsule)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("播放速度")
        .accessibilityValue("\(rate.formatted())×")
    }
    #endif

    // MARK: - 两侧

    private func leftColumn(landscape: Bool) -> some View {
        let size: CGFloat = landscape ? 52 : 44
        return VStack(spacing: 20) {
            if buttons.screenshot {
                circleButton("camera", label: "截图", size: size) { session.captureScreenshot() }
            }
            circleButton("lock.open", label: "锁定屏幕", size: size) {
                controller.isLocked = true
                controller.touchControls()
            }
        }
    }

    /// 右侧倍速：上下按钮按 0.25× 微调，中间点按展开预设。
    private func speedControl(landscape: Bool) -> some View {
        let size: CGFloat = landscape ? 48 : 40
        let rate = controller.engine.rate
        return VStack(spacing: 12) {
            circleButton("plus", label: "加快播放", size: size) { stepSpeed(Self.speedStep) }
                .disabled(rate >= Self.speedRange.upperBound - 0.001)
            Menu {
                Picker("播放速度", selection: Binding(
                    get: { controller.engine.rate },
                    set: { controller.engine.setRate($0) }
                )) {
                    ForEach(Self.speedPresets, id: \.self) { speed in
                        Text(speed == 1 ? "正常" : "\(speed.formatted())×").tag(speed)
                    }
                }
                pinWhileOpen
            } label: {
                // 与按钮相同的半透明底：倍速值浮在画面中部，亮画面上没有底色会看不清。
                Text("\(rate.formatted())×")
                    .font(.subheadline.weight(rate == 1 ? .medium : .bold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .frame(minWidth: size, minHeight: 32)
                    .background(Capsule().fill(Self.buttonFill))
                    .contentShape(.capsule)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("播放速度")
            .accessibilityValue("\(rate.formatted())×")
            circleButton("minus", label: "减慢播放", size: size) { stepSpeed(-Self.speedStep) }
                .disabled(rate <= Self.speedRange.lowerBound + 0.001)
        }
    }

    /// 按步长调整并对齐到 0.05×，消除浮点累加误差。
    private func stepSpeed(_ delta: Float) {
        let stepped = ((controller.engine.rate + delta) * 20).rounded() / 20
        controller.engine.setRate(min(max(stepped, Self.speedRange.lowerBound), Self.speedRange.upperBound))
        controller.touchControls()
    }

    // MARK: - 中央

    private func transportControls(landscape: Bool) -> some View {
        HStack(spacing: landscape ? 48 : 28) {
            if buttons.seek {
                circleButton(Self.seekSymbol("gobackward", controller.preferences.seekBackwardSeconds), label: "快退", size: 56, iconScale: 0.5) {
                    controller.skipBackward()
                }
            }
            if buttons.playPause {
                playPauseButton
            }
            if buttons.seek {
                circleButton(Self.seekSymbol("goforward", controller.preferences.seekForwardSeconds), label: "快进", size: 56, iconScale: 0.5) {
                    controller.skipForward()
                }
            }
        }
    }

    /// SF Symbols 只提供部分秒数的快进 / 快退图标，其余用通用图标。
    private static func seekSymbol(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    /// 播放 / 暂停；缓冲时转圈占据按钮位置。开启「长按播放暂停键退出播放器」时长按关闭播放器。
    private var playPauseButton: some View {
        let status = controller.engine.status
        let buffering = status == .buffering || status == .loading || session.isSwitchingStream
        return ZStack {
            Circle().fill(Self.buttonFill)
            if buffering {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 76, height: 76)
        .contentShape(.circle)
        .onTapGesture { controller.togglePlayPause() }
        .onLongPressGesture(minimumDuration: 0.6) {
            if controller.preferences.longPressPlayPauseExits { onClose() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(controller.isPlaying ? "暂停" : "播放")
        .accessibilityAction { controller.togglePlayPause() }
    }

    // MARK: - 底部

    private func bottomSection(landscape: Bool, chrome: Double) -> some View {
        // 剧集与多段文件（CD1 / CD2）都提供上一个 / 下一个。
        let hasNavigation = (session.item?.kind == .episode || session.partPosition != nil) && buttons.switchMedia
        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                if hasNavigation { episodeNavigation }
                titleBlock
                Spacer(minLength: 0)
            }
            .opacity(chrome)

            HStack(spacing: 12) {
                PlaybackTimeLabel(controller: controller)
                PlayerScrubber(controller: controller, chapterStarts: session.chapters.map(\.chapter.start))
                if landscape {
                    bottomActions.opacity(chrome)
                }
            }
            if !landscape {
                bottomActions
                    .padding(.top, 8)
                    .opacity(chrome)
            }
        }
        .padding(.horizontal, landscape ? 12 : 12)
        .padding(.bottom, landscape ? 8 : 12)
    }

    private var episodeNavigation: some View {
        HStack(spacing: 8) {
            let isPart = session.partPosition != nil
            circleButton("backward.end.fill", label: isPart ? "上一段" : "上一集", size: Self.barButtonSize) { session.playPreviousEpisode() }
                .disabled(session.previousEpisode == nil)
            circleButton("forward.end.fill", label: isPart ? "下一段" : "下一集", size: Self.barButtonSize) { controller.playNextNow() }
                .disabled(session.nextEpisode == nil)
                // 下一集已预加载：服务器已开始准备，切换会更快。
                .overlay(alignment: .topTrailing) {
                    if session.isNextPreloaded {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("已预加载")
                    }
                }
        }
    }

    /// 标题块：剧名（次要）+ 单集 / 片名 + HDR 标记；点按打开单集信息。
    private var titleBlock: some View {
        let title = controller.source?.title ?? ""
        let subtitle = controller.source?.subtitle
        return Button { open(.episodeInfo) } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    if subtitle != nil {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    HStack(spacing: 8) {
                        Text(subtitle ?? title)
                            .font(.headline)
                        if let hdr = session.dynamicRangeLabel {
                            Text(hdr)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.72), lineWidth: 1))
                        }
                    }
                }
                .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看单集信息")
        .playerPanelPopover([.episodeInfo], panel: $panel, session: session, arrowEdge: .top)
    }

    /// 串流画质 / 剧集或分段 / 音轨 / 字幕（与 Android 版顺序一致）。
    private var bottomActions: some View {
        HStack(spacing: 12) {
            // 串流画质只对服务器条目有意义（由服务器按码率上限转码）。
            if session.item != nil {
                circleButton(session.maxBitrateOverride == nil ? "sparkles.tv" : "sparkles.tv.fill", label: "串流画质", size: Self.barButtonSize) { open(.quality) }
                    .disabled(session.isSwitchingStream)
                    .playerPanelPopover([.quality], panel: $panel, session: session, arrowEdge: .top)
            }
            if !session.seasonEpisodes.isEmpty {
                circleButton("list.bullet", label: "剧集列表", size: Self.barButtonSize) { open(.episodes) }
                    .playerPanelPopover([.episodes], panel: $panel, session: session, arrowEdge: .top)
            }
            if session.partPosition != nil, !session.parts.isEmpty {
                circleButton("list.bullet", label: "分段列表", size: Self.barButtonSize) { open(.parts) }
                    .playerPanelPopover([.parts], panel: $panel, session: session, arrowEdge: .top)
            }
            if !session.audioOptions.isEmpty {
                let isMuted = controller.engine.isMuted
                circleButton(isMuted ? "speaker.slash" : "waveform", label: isMuted ? "音轨（已静音）" : "音轨", size: Self.barButtonSize) { open(.audio) }
                    .disabled(session.isSwitchingStream)
                    .playerPanelPopover([.audio], panel: $panel, session: session, arrowEdge: .top)
            }
            circleButton(session.selectedSubtitleIndex == nil ? "captions.bubble" : "captions.bubble.fill", label: "字幕", size: Self.barButtonSize) {
                open(.subtitle)
            }
            .disabled(session.isSwitchingStream)
            .playerPanelPopover([.subtitle], panel: $panel, session: session, arrowEdge: .top)
        }
    }

    // MARK: - 通用

    /// 圆形按钮底色，与 Android 版 `OverlayButtonFill` 相同。
    static let buttonFill = Color.black.opacity(0.36)

    /// 顶栏与底栏按钮的直径：iOS 按触控目标取 44pt；macOS 用鼠标操作，取接近系统工具栏控件的 32pt。
    #if os(macOS)
    static let barButtonSize: CGFloat = 32
    #else
    static let barButtonSize: CGFloat = 44
    #endif

    private func circleButton(_ symbol: String, label: String, size: CGFloat, iconScale: CGFloat = 0.45, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * iconScale, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(OverlayCircleButtonStyle(size: size))
        .accessibilityLabel(label)
    }

    private func lockedOverlay(landscape: Bool) -> some View {
        HStack {
            circleButton("lock.fill", label: "解除锁定", size: 52) {
                controller.isLocked = false
                controller.touchControls()
            }
            Spacer()
        }
        .padding(.horizontal, landscape ? 28 : 12)
        .frame(maxHeight: .infinity)
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

private extension View {
    /// macOS：`targets` 中的面板打开时从这个控件弹出 popover；iOS 不变（面板由 `PlayerScreen` 的 `PlayerPanelHost` 显示）。
    /// 一个面板只锚在一个控件上（例如「媒体信息」只锚在顶栏的信息按钮，「更多」菜单里的同名项也从那里弹出）。
    @ViewBuilder
    func playerPanelPopover(_ targets: Set<PlayerPanel>, panel: Binding<PlayerPanel?>, session: PlayerSession, arrowEdge: Edge) -> some View {
        #if os(macOS)
        popover(
            isPresented: Binding(
                get: { panel.wrappedValue.map(targets.contains) ?? false },
                set: { presented in
                    if !presented, let current = panel.wrappedValue, targets.contains(current) { panel.wrappedValue = nil }
                }
            ),
            arrowEdge: arrowEdge
        ) {
            if let current = panel.wrappedValue, targets.contains(current) {
                PlayerPanelPopover(panel: current, session: session) { panel.wrappedValue = nil }
            }
        }
        #else
        self
        #endif
    }
}

/// 半透明圆底按钮：按下时轻微缩小；禁用时降低不透明度。
private struct OverlayCircleButtonStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        CircleLabel(configuration: configuration, size: size)
    }

    private struct CircleLabel: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(PlayerControlsView.buttonFill))
                .contentShape(.circle)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.spring(duration: 0.2), value: configuration.isPressed)
        }
    }
}

/// 「当前 / 总时长」：点按在总时长与剩余时长之间切换（「进度条时间模式」）。
/// 独立子视图：进度每 0.25 秒变化一次，只让这段文字刷新，不牵动整个控制层。
private struct PlaybackTimeLabel: View {
    let controller: PlayerController

    var body: some View {
        let position = controller.scrubTime ?? controller.engine.currentTime
        let duration = controller.engine.duration
        let remaining = controller.preferences.progressTimeMode == .remaining && duration > 0
        // 时长未知（起播中、直播）时不显示误导性的 0:00。
        let total = duration <= 0 ? "--:--" : remaining ? "-" + PlayerTime.format(max(0, duration - position)) : PlayerTime.format(duration)
        Text("\(PlayerTime.format(position))\(Text(" / \(total)").foregroundStyle(.white.opacity(0.72)))")
            .font(.footnote.weight(.medium).monospacedDigit())
            .padding(.vertical, 6)
            .contentShape(.rect)
            .onTapGesture {
                let preferences = controller.preferences
                preferences.progressTimeMode = preferences.progressTimeMode == .total ? .remaining : .total
                controller.touchControls()
            }
    }
}

// MARK: - 进度条

/// 细进度条：未播放 / 已缓冲 / 已播放三段，拖动时放大滑块，并在上方浮出跟随位置的预览帧。
/// 不用系统 `Slider`：需要缓冲段，并且预览帧要按滑块的横向位置定位。
/// 进度条：已播放段为主题色直线，未播放的轨道按章节起点分段并留出间隙（与 Android 一致），滑块为竖条。
private struct PlayerScrubber: View {
    let controller: PlayerController
    /// 章节起点（秒），用于把未播放轨道分段；为空时为一整段。
    var chapterStarts: [TimeInterval] = []

    private static let segmentGap: CGFloat = 5
    static let playedTint = VelaTheme.accentLight

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

            Canvas { context, size in
                draw(in: &context, size: size, progress: progress, buffered: buffered, duration: duration, thick: isScrubbing)
            }
            .frame(height: 8)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white)
                    .frame(width: isScrubbing ? 6 : 4, height: isScrubbing ? 26 : 20)
                    .offset(x: width * progress - (isScrubbing ? 3 : 2))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .overlay(alignment: .bottomLeading) {
                if isScrubbing, controller.scrubPreview.isEnabled, controller.preferences.scrubPreview == .window {
                    let size = previewSize(trackWidth: width)
                    ScrubPreviewFrame(controller: controller, size: size)
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
    private func draw(in context: inout GraphicsContext, size: CGSize, progress: Double, buffered: Double,
                      duration: TimeInterval, thick: Bool) {
        let width = size.width
        let midY = size.height / 2
        let lineWidth: CGFloat = thick ? 6 : 4
        let playedX = width * progress
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        // 未播放轨道：章节边界处断开；与已播放段之间也留出间隙，像 Android 一样把滑块两侧分开。
        let bounds = [0] + chapterStarts
            .filter { duration > 0 && $0 > 0 && $0 < duration }
            .map { CGFloat($0 / duration) * width } + [width]
        // 已缓冲段从间隙之后起算并整体后移间隙宽度：内核默认只预读几十秒，长片中只有一两个点宽，
        // 按绝对位置画会被滑块后的间隙完全吞掉。
        let bufferedX = playedX + Self.segmentGap + lineWidth / 2 + max(0, width * buffered - playedX)
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            let start = max(a + (a > 0 ? Self.segmentGap / 2 : 0), playedX + Self.segmentGap + lineWidth / 2)
            let end = b - (b < width ? Self.segmentGap / 2 : 0)
            guard end > start else { continue }
            var track = Path()
            track.move(to: CGPoint(x: start, y: midY))
            track.addLine(to: CGPoint(x: end, y: midY))
            context.stroke(track, with: .color(.white.opacity(0.25)), style: style)
            if bufferedX > start {
                var loaded = Path()
                loaded.move(to: CGPoint(x: start, y: midY))
                loaded.addLine(to: CGPoint(x: min(end, bufferedX), y: midY))
                context.stroke(loaded, with: .color(.white.opacity(0.45)), style: style)
            }
        }

        guard playedX > lineWidth / 2 else { return }
        var played = Path()
        played.move(to: CGPoint(x: lineWidth / 2, y: midY))
        played.addLine(to: CGPoint(x: playedX, y: midY))
        context.stroke(played, with: .color(Self.playedTint), style: style)
    }

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
    let controller: PlayerController
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            if let image = controller.scrubPreview.image {
                // 预览框 2 倍像素即可，再大只是放大低分辨率的预览源。
                ScrubPreviewImage(image: image, controller: controller, pixelSize: CGSize(width: size.width * 2, height: size.height * 2))
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

/// 拖动预览帧：开启 VR 转平面时按当前视角转成平面画面，与主画面一致（否则预览显示的是整幅 VR 原图）。
///
/// 转换在后台进行；新帧转换完成前继续显示上一张转换结果，避免在 VR 原图与平面画面之间闪烁。
struct ScrubPreviewImage: View {
    let image: CGImage
    let controller: PlayerController
    /// 转平面输出的像素尺寸（决定宽高比与清晰度）。
    let pixelSize: CGSize

    @State private var flattened: (source: ObjectIdentifier, image: CGImage)?

    private struct FlattenKey: Hashable {
        var source: ObjectIdentifier
        var layout: VRLayout?
        var view: VRViewState
        var width: Int
        var height: Int
    }

    var body: some View {
        let layout = controller.vrEnabled ? controller.effectiveVRLayout : nil
        Group {
            if layout == nil {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if let flattened {
                Image(decorative: flattened.image, scale: 1).resizable().scaledToFill()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: FlattenKey(
            source: ObjectIdentifier(image), layout: layout, view: controller.vrState,
            width: Int(pixelSize.width), height: Int(pixelSize.height)
        )) {
            guard let layout else {
                flattened = nil
                return
            }
            let source = image, view = controller.vrState, size = pixelSize
            let result = await Task.detached(priority: .userInitiated) {
                VRPreviewFlattener.flatten(source, layout: layout, view: view, outputSize: size)
            }.value
            guard !Task.isCancelled, let result else { return }
            flattened = (ObjectIdentifier(source), result)
        }
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
