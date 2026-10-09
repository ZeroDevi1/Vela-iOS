import SwiftUI
import VelaPlayer
#if os(iOS)
import UIKit
#endif

/// 播放器页面。iPhone / iPad 全屏覆盖呈现；macOS 作为独立窗口打开（`windowID`）。
public struct PlayerScreen: View {
    /// macOS 播放器窗口的 WindowGroup id。
    public static let windowID = "player"

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session: PlayerSession
    @State private var panel: PlayerPanel?
    #if os(macOS)
    /// 播放器所在窗口：「画中画」时原地变成置顶小窗（`MiniPlayerWindow`）。
    @State private var window: NSWindow?
    @State private var miniWindow = MiniPlayerWindow()
    /// Esc 的本地按键监听（见 `PlayerCommands.exitFullScreenOrClose`）。
    @State private var escapeMonitor: Any?
    /// 滚轮 / 触控板横扫快进快退的本地事件监听。
    @State private var scrollMonitor: Any?
    @State private var scrollSeek = ScrollSeekAccumulator()
    /// 控制层隐藏时鼠标在画面底部：只浮出进度条（`MacProgressPeek`）。
    @State private var progressPeek = false
    #endif

    public init(request: PlaybackRequest) {
        _session = State(initialValue: PlayerSession(request: request))
    }

    /// - Parameter resuming: 画中画中的原会话；非 nil 时直接接管，不重新起播。
    init(request: PlaybackRequest, resuming: PlayerSession?) {
        _session = State(initialValue: resuming ?? PlayerSession(request: request))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // VR 转平面正常出画面时隐藏底层平面画面：两层全屏视频叠在一起只会多一次合成，且底层完全被遮住。
            // VR 出错时保留底层画面，用户至少能看到原始排布。
            RotatableSurface(controller: session.controller)
                .opacity(session.controller.vrEnabled && session.controller.vrIssue == nil ? 0 : 1)
                .ignoresSafeArea()

            if session.controller.vrEnabled, let layout = session.controller.effectiveVRLayout {
                VRVideoView(controller: session.controller, layout: layout)
                    // 切换内核后重建：画面来源随内核不同（视频输出 / KSPlayer 解码帧）。
                    .id(ObjectIdentifier(session.controller.engine))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // 「进度条预览：全屏模式」：拖动时预览帧铺满画面。
            if session.controller.scrubTime != nil, app.playerPreferences.scrubPreview == .fullscreen,
               let frame = session.controller.scrubPreview.image {
                GeometryReader { proxy in
                    // VR 转平面时按屏幕宽高比输出（长边 720 像素），与主画面的取景一致。
                    let longSide = max(proxy.size.width, proxy.size.height, 1)
                    ScrubPreviewImage(
                        image: frame,
                        controller: session.controller,
                        pixelSize: CGSize(width: 720 * proxy.size.width / longSide, height: 720 * proxy.size.height / longSide)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .background(.black)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            // macOS 系统画中画期间窗口里没有画面，字幕改由小窗里的码流字幕轨显示。
            if !isSystemPictureInPictureOnMac {
                SubtitleOverlay(controller: session.controller, preferences: app.playerPreferences, fitsSmallWindow: isMiniWindow)
            }

            if isMiniWindow {
                #if os(macOS)
                MiniPlayerOverlay(controller: session.controller) {
                    session.controller.isMiniWindow = false
                } onClose: {
                    close()
                }
                .ignoresSafeArea()
                #endif
            } else {
                PlayerOSD(controller: session.controller)

                #if os(macOS)
                PlayerGestureLayer(controller: session.controller, progressPeek: $progressPeek)
                    .ignoresSafeArea()
                #else
                PlayerGestureLayer(controller: session.controller)
                    .ignoresSafeArea()
                #endif
            }

            switch session.phase {
            case .preparing:
                ProgressView().controlSize(.large).tint(.white)
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法播放", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { Task { await session.prepare(app: app) } }
                        .buttonStyle(.glass)
                    Button("关闭", action: close)
                        .buttonStyle(.glass)
                }
                .foregroundStyle(.white)
            case .ready:
                if case .failed(let message) = session.controller.engine.status {
                    ContentUnavailableView {
                        Label("播放出错", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("从当前位置重试") { session.retryAfterFailure() }
                            .buttonStyle(.glass)
                        if session.item != nil, session.controller.engine.kind == .avFoundation {
                            Button("用 KSPlayer 内核重试") { session.retryWithKSPlayer() }
                                .buttonStyle(.glass)
                        }
                        Button("关闭", action: close)
                            .buttonStyle(.glass)
                    }
                    .foregroundStyle(.white)
                }
                // 控制层显示时播放键本身会转圈（与 Android 版一致），这里只在控制层隐藏时显示。
                if !session.controller.controlsVisible || session.controller.isLocked || isMiniWindow,
                   session.isSwitchingStream || session.controller.engine.status == .buffering
                    || session.controller.engine.status == .loading {
                    ProgressView().controlSize(isMiniWindow ? .regular : .large).tint(.white).allowsHitTesting(false)
                }
                if !isMiniWindow {
                    fullControls
                }
            }
        }
        .animation(.snappy, value: session.screenshot != nil)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!session.controller.controlsVisible)
        .persistentSystemOverlays(session.controller.controlsVisible ? .automatic : .hidden)
        #else
        .navigationTitle(session.request.title)
        .frame(minWidth: isMiniWindow ? MiniPlayerWindow.minimumWidth : 640, minHeight: isMiniWindow ? 135 : 360)
        #endif
        .task { await session.prepareIfNeeded(app: app) }
        #if os(iOS)
        .onAppear(perform: adoptSession)
        #else
        .background(PlayerWindowReader { window = $0 })
        .onChange(of: session.controller.isMiniWindow) { _, mini in
            guard let window else { return }
            if mini {
                panel = nil
                miniWindow.enter(window, videoSize: session.controller.engine.videoSize)
            } else {
                miniWindow.exit()
            }
        }
        // 小窗里放不下错误卡片与重试按钮：出错时回到播放器窗口。
        .onChange(of: session.controller.engine.status) { _, status in
            if case .failed = status, session.controller.isMiniWindow { session.controller.isMiniWindow = false }
        }
        // 菜单栏「播放」作用于当前在前的播放器窗口。
        .focusedSceneValue(\.playerSession, session)
        // 控制层自动隐藏时一并隐藏鼠标指针，移动鼠标即恢复（与控制层同时出现）。
        .onChange(of: session.controller.controlsVisible) { _, visible in
            if !visible, !isMiniWindow { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .onAppear(perform: installEscapeMonitor)
        .onAppear(perform: installScrollMonitor)
        .onChange(of: session.controller.controlsVisible) { _, visible in
            if visible { progressPeek = false }
        }
        .animation(.easeOut(duration: 0.15), value: progressPeek)
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            miniWindow.teardown()
        }
        #endif
        #if os(iOS)
        // 「暂停后自动锁屏」关闭时，播放器打开期间始终常亮；开启时交给 AVPlayer（只在播放视频时阻止锁屏）。
        .onChange(of: app.playerPreferences.lockWhenPaused, initial: true) { _, lockWhenPaused in
            UIApplication.shared.isIdleTimerDisabled = !lockWhenPaused
        }
        #endif
        .onDisappear {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            PlayerBrightness.leave()
            OrientationController.unlock()
            // 画中画开始时收起播放页：会话交给 AppModel 继续播放，不结束。
            if app.pictureInPictureSession === session, session.controller.isPictureInPictureActive { return }
            if app.pictureInPictureSession === session { app.pictureInPictureSession = nil }
            #endif
            session.close()
        }
    }

    /// macOS 小窗模式（iOS 恒为 false）。
    private var isSystemPictureInPictureOnMac: Bool {
        #if os(macOS)
        session.controller.isPictureInPictureActive
        #else
        false
        #endif
    }

    private var isMiniWindow: Bool {
        #if os(macOS)
        session.controller.isMiniWindow
        #else
        false
        #endif
    }

    /// 控制层、跳过 / 下一集卡片、提示与面板；小窗模式下不显示。
    @ViewBuilder
    private var fullControls: some View {
        PlayerHUDView(controller: session.controller)
        PlayerControlsView(session: session, panel: $panel, onClose: close)
        SkipSegmentButton(controller: session.controller)
        UpNextCard(controller: session.controller)
        ScreenshotToast(session: session)
        if session.controller.vrEnabled, let issue = session.controller.vrIssue {
            VideoIssueCard(session: session, message: issue, symbol: "visionpro") {
                Button("关闭 VR 转平面") { session.controller.toggleVR() }
                    .buttonStyle(.glass)
            }
        } else if let issue = (session.controller.engine as? any VideoDecodeDiagnosing)?.videoDecodeIssue {
            VideoIssueCard(session: session, message: issue, symbol: "exclamationmark.triangle") { EmptyView() }
        }
        if let error = session.trackError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(10)
                .glassEffect(.regular, in: .capsule)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 72)
        }
        #if os(macOS)
        // 面板在 macOS 上是锚在控制层按钮上的 popover（`playerPanelPopover`）。
        if progressPeek, !session.controller.controlsVisible, session.phase == .ready {
            MacProgressPeek(controller: session.controller, chapterStarts: session.chapters.map(\.chapter.start))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .onHover { if !$0 { progressPeek = false } }
                .transition(.opacity)
        }
        #else
        if let panel {
            PlayerPanelHost(panel: panel, session: session) {
                withAnimation(.snappy) { self.panel = nil }
                session.controller.touchControls()
            }
        }
        #endif
    }

    #if os(iOS)
    /// 接管会话并挂上画中画事件：开始时收起播放页，恢复时重新呈现，用户关闭小窗时结束播放。
    private func adoptSession() {
        let controller = session.controller
        PlayerBrightness.enter(app.playerPreferences)
        if app.pictureInPictureSession === session {
            app.pictureInPictureSession = nil
            // 不是经由小窗「恢复」按钮回来（例如在详情页再次点播同一条目）：结束画中画，回到页内播放。
            if controller.isPictureInPictureActive, !controller.isRestoringPictureInPicture {
                controller.stopPictureInPicture()
            }
        }
        let app = app
        // 收起 / 恢复播放页都不做动画：系统此时正在播放小窗的缩放动画，两段动画叠在一起会明显掉帧。
        var instant = Transaction()
        instant.disablesAnimations = true
        controller.onPictureInPictureStart = { [weak session] in
            guard let session else { return }
            app.pictureInPictureSession = session
            withTransaction(instant) { app.presentedPlayback = nil }
        }
        controller.onPictureInPictureRestore = { [weak session] completion in
            guard let session else { return completion(false) }
            withTransaction(instant) { app.presentedPlayback = session.request }
            // 等播放页挂上画面视图（下一帧布局完成）再通知系统，小窗会动画回到画面位置。
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                completion(true)
            }
        }
        controller.onPictureInPictureStop = { [weak session] restored in
            guard let session, !restored else { return }
            // 播放页正在显示这个会话（例如再次点播同一条目）时由播放页继续；否则是用户关闭了小窗。
            if app.presentedPlayback?.id == session.request.id, app.pictureInPictureSession !== session { return }
            if app.pictureInPictureSession === session { app.pictureInPictureSession = nil }
            session.close()
        }
    }
    #endif

    #if os(macOS)
    /// 窗口模式下 Esc 到不了菜单栏的快捷键（SwiftUI 宿主视图先处理掉了），在本窗口的按键事件进入分发前拦截。
    /// 只处理不带修饰键、发往本播放器窗口的 Esc；面板打开时交给面板（Esc 关闭面板）。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === window, panel == nil,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            // 小窗时 Esc 回到播放器窗口，不关闭。
            if session.controller.isMiniWindow {
                session.controller.isMiniWindow = false
                return nil
            }
            PlayerCommands.exitFullScreenOrClose(event.window)
            return nil
        }
    }

    /// 滚轮 / 触控板横扫快进快退（第 3.5 节）：只处理发往本播放器窗口、没有打开面板、非小窗时的滚动；
    /// 惯性滚动阶段忽略，避免松手后继续跳。每跨过一个步长执行一次快进 / 快退（步长取「快进 / 快退时间」设置）。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === window, panel == nil, !session.controller.isMiniWindow,
                  session.phase == .ready, event.momentumPhase.isEmpty else { return event }
            guard let direction = scrollSeek.consume(event) else { return event }
            if direction > 0 { session.controller.skipForward() } else { session.controller.skipBackward() }
            return nil
        }
    }
    #endif

    private func close() {
        session.close()
        dismiss()
    }
}

#if os(macOS)
/// 把滚动事件换算为快进 / 快退次数。
/// - 触控板（精确滚动）：只认横向为主的滑动，手指向右为快进（按 `isDirectionInvertedFromDevice` 还原手指方向，
///   与「自然滚动」设置无关），累计 60pt 触发一次；纵向滑动不处理，避免误触。
/// - 鼠标滚轮（非精确）：每格一次，向上为快进；按住 Shift 时系统把滚轮转为横向，同样处理。
struct ScrollSeekAccumulator {
    private var accumulated: CGFloat = 0
    private static let trackpadStep: CGFloat = 60

    /// - Returns: 1 快进、-1 快退；未达步长或不是快进快退手势时返回 nil（事件交还给系统）。
    mutating func consume(_ event: NSEvent) -> Int? {
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) { accumulated = 0 }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard abs(dx) > abs(dy) else { return nil }
            accumulated += event.isDirectionInvertedFromDevice ? dx : -dx
            guard abs(accumulated) >= Self.trackpadStep else { return nil }
            let direction = accumulated > 0 ? 1 : -1
            accumulated = 0
            return direction
        }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
        guard delta != 0 else { return nil }
        return delta > 0 ? 1 : -1
    }
}

/// 取得 SwiftUI 视图所在的 `NSWindow`（加入窗口后回调一次）。
private struct PlayerWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { self.onWindow(window) }
        }
    }
}
#endif

/// 渲染表面 + 画面旋转。旋转 90° / 270° 时交换宽高再旋转，使画面在新方向上仍按比例适应容器。
private struct RotatableSurface: View {
    let controller: PlayerController

    var body: some View {
        GeometryReader { proxy in
            let turned = controller.quarterTurns % 2 == 1
            PlayerSurface(controller: controller)
                // 切换内核后重建渲染视图（AVPlayerLayer ↔ CAMetalLayer）。
                .id(ObjectIdentifier(controller.engine))
                .frame(
                    width: turned ? proxy.size.height : proxy.size.width,
                    height: turned ? proxy.size.width : proxy.size.height
                )
                .rotationEffect(.degrees(Double(controller.quarterTurns) * 90))
                // 双指缩放 / 移动画面。
                .scaleEffect(controller.zoomScale)
                .offset(controller.zoomOffset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .animation(.snappy, value: controller.quarterTurns)
    }
}

/// 有声音但没有画面（系统解码器打不开，或 VR 转平面取不到帧）：说明原因并给出可行的出路。
/// - 改用 KSPlayer：FFmpeg 解封装后交给硬件解码，可绕过 `hev1` 标签等系统播放器的限制。
/// - 服务器转码为 4K：本机硬件解码有分辨率上限（如 8192 宽的 8K），只能让服务器缩小后重新编码。
private struct VideoIssueCard<Extra: View>: View {
    let session: PlayerSession
    let message: String
    let symbol: String
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(spacing: 10) {
            Label(message, systemImage: symbol)
                .font(.footnote)
            HStack(spacing: 8) {
                if session.controller.engine.kind == .avFoundation, session.canSwitchEngine {
                    Button("用 KSPlayer 重试") { session.retryWithKSPlayer() }
                        .buttonStyle(.bordered)
                }
                if session.item != nil, !session.isServerDownscaled {
                    Button("服务器转码为 4K") { session.retryWithServerDownscale() }
                        .buttonStyle(.bordered)
                }
                extra()
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
}
