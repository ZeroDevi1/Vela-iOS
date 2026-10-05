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

            RotatableSurface(controller: session.controller)
                .ignoresSafeArea()

            if session.controller.vrEnabled, let layout = session.controller.effectiveVRLayout {
                VRVideoView(controller: session.controller, layout: layout)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // 「进度条预览：全屏模式」：拖动时预览帧铺满画面。
            if session.controller.scrubTime != nil, app.playerPreferences.scrubPreview == .fullscreen,
               let frame = session.controller.scrubPreview.image {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            Button("用 MPV 内核重试") { session.retryWithMPV() }
                                .buttonStyle(.glass)
                        }
                        Button("关闭", action: close)
                            .buttonStyle(.glass)
                    }
                    .foregroundStyle(.white)
                }
                if session.isSwitchingStream || session.controller.engine.status == .buffering
                    || session.controller.engine.status == .loading {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }
                PlayerHUDView(controller: session.controller)
                PlayerControlsView(session: session, panel: $panel, onClose: close)
                SkipSegmentButton(controller: session.controller)
                UpNextCard(controller: session.controller)
                ScreenshotToast(session: session)
                if session.controller.vrEnabled, let issue = session.controller.vrIssue {
                    VStack(spacing: 8) {
                        Label(issue, systemImage: "visionpro")
                            .font(.footnote)
                        Button("关闭 VR 转平面") { session.controller.toggleVR() }
                            .buttonStyle(.glass)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 24)
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
        controller.onPictureInPictureStart = { [weak session] in
            guard let session else { return }
            app.pictureInPictureSession = session
            app.presentedPlayback = nil
        }
        controller.onPictureInPictureRestore = { [weak session] completion in
            guard let session else { return completion(false) }
            app.presentedPlayback = session.request
            // 等全屏覆盖呈现动画走完再通知系统，小窗会动画回到画面位置。
            Task {
                try? await Task.sleep(for: .milliseconds(450))
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

    private func close() {
        session.close()
        dismiss()
    }
}

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
