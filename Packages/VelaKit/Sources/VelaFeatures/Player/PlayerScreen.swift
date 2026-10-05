import SwiftUI
import VelaPlayer

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

            SubtitleOverlay(controller: session.controller, preferences: app.playerPreferences)

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
        .task { await session.prepare(app: app) }
        .onDisappear {
            session.close()
            #if os(iOS)
            OrientationController.unlock()
            #endif
        }
    }

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
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.snappy, value: controller.quarterTurns)
    }
}
