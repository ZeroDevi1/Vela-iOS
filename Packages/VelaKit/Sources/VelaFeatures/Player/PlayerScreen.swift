import SwiftUI
import VelaPlayer

/// 播放器页面。iPhone / iPad 全屏覆盖呈现；macOS 作为独立窗口打开（`windowID`）。
public struct PlayerScreen: View {
    /// macOS 播放器窗口的 WindowGroup id。
    public static let windowID = "player"

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session: PlayerSession

    public init(request: PlaybackRequest) {
        _session = State(initialValue: PlayerSession(request: request))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(controller: session.controller)
                .ignoresSafeArea()

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
                        Button("关闭", action: close)
                            .buttonStyle(.glass)
                    }
                    .foregroundStyle(.white)
                }
                PlayerHUDView(controller: session.controller)
                PlayerControlsView(session: session, onClose: close)
                SkipSegmentButton(controller: session.controller)
                UpNextCard(controller: session.controller)
                if session.isSwitchingStream {
                    ProgressView().controlSize(.large).tint(.white)
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
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!session.controller.controlsVisible)
        .persistentSystemOverlays(session.controller.controlsVisible ? .automatic : .hidden)
        #else
        .navigationTitle(session.request.title)
        .frame(minWidth: 640, minHeight: 360)
        #endif
        .task { await session.prepare(app: app) }
        .onDisappear { session.close() }
    }

    private func close() {
        session.close()
        dismiss()
    }
}
