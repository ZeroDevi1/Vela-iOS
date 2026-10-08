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
    /// 播放器所在窗口：画中画期间隐藏，恢复时重新显示。
    @State private var window: NSWindow?
    /// Esc 的本地按键监听（见 `PlayerCommands.exitFullScreenOrClose`）。
    @State private var escapeMonitor: Any?
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

            SubtitleOverlay(controller: session.controller, preferences: app.playerPreferences)

            PlayerOSD(controller: session.controller)

            PlayerGestureLayer(controller: session.controller)
                .ignoresSafeArea()

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
                if !session.controller.controlsVisible || session.controller.isLocked,
                   session.isSwitchingStream || session.controller.engine.status == .buffering
                    || session.controller.engine.status == .loading {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }
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
                if let panel {
                    PlayerPanelHost(panel: panel, session: session) {
                        withAnimation(.snappy) { self.panel = nil }
                        session.controller.touchControls()
                    }
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
        .frame(minWidth: 640, minHeight: 360)
        #endif
        .task { await session.prepareIfNeeded(app: app) }
        #if os(iOS)
        .onAppear(perform: adoptSession)
        #else
        .background(PlayerWindowReader { window = $0 })
        .onAppear(perform: adoptSessionInWindow)
        // 菜单栏「播放」作用于当前在前的播放器窗口。
        .focusedSceneValue(\.playerSession, session)
        // 控制层自动隐藏时一并隐藏鼠标指针，移动鼠标即恢复（与控制层同时出现）。
        .onChange(of: session.controller.controlsVisible) { _, visible in
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .onAppear(perform: installEscapeMonitor)
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
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
    /// macOS 的播放器是独立窗口，画中画开始时窗口原地只剩系统的「正以画中画播放」占位：
    /// 开始时隐藏窗口（会话与视图都保留，`orderOut` 不触发 `onDisappear`），恢复时重新显示后再通知系统，
    /// 用户在小窗上关闭时结束播放并关闭窗口。
    /// 窗口模式下 Esc 到不了菜单栏的快捷键（SwiftUI 宿主视图先处理掉了），在本窗口的按键事件进入分发前拦截。
    /// 只处理不带修饰键、发往本播放器窗口的 Esc；面板打开时交给面板（Esc 关闭面板）。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === window, panel == nil,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            PlayerCommands.exitFullScreenOrClose(event.window)
            return nil
        }
    }

    private func adoptSessionInWindow() {
        let controller = session.controller
        controller.onPictureInPictureStart = {
            window?.orderOut(nil)
        }
        controller.onPictureInPictureRestore = { completion in
            window?.makeKeyAndOrderFront(nil)
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                completion(true)
            }
        }
        controller.onPictureInPictureStop = { restored in
            guard !restored else { return }
            session.close()
            window?.close()
        }
    }
    #endif

    private func close() {
        session.close()
        dismiss()
    }
}

#if os(macOS)
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
                        .buttonStyle(.glass)
                }
                if session.item != nil, !session.isServerDownscaled {
                    Button("服务器转码为 4K") { session.retryWithServerDownscale() }
                        .buttonStyle(.glass)
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
