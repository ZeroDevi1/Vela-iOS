import SwiftUI
import VelaDesignSystem

/// 应用根视图：没有服务器时进入引导，否则进入主界面。负责注入播放入口与布局环境。
public struct VelaRootView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        @Bindable var app = app
        Group {
            if app.servers.servers.isEmpty {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .tint(VelaTheme.accent)
        .velaPlaybackEnvironment()
        #if os(iOS)
        .environment(\.isCompactLayout, sizeClass == .compact)
        .fullScreenCover(item: $app.presentedPlayback) { request in
            PlayerScreen(request: request)
        }
        #endif
        .overlay(alignment: .top) {
            LineSwitchBanner().animation(.snappy, value: app.lineRouter.notice)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.lineRouter.appDidBecomeActive() }
        }
        // 进入多任务切换器时遮挡私密服务器内容，防止快照泄露。
        .overlay {
            if scenePhase != .active, app.servers.activeServer?.isPrivate == true {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
        }
    }
}

extension View {
    /// 注入播放入口：iPhone / iPad 设置全屏覆盖的播放请求，macOS 打开播放器窗口。
    /// 任何可能发起播放的场景根视图（主窗口、macOS 设置窗口）都需要调用。
    public func velaPlaybackEnvironment() -> some View {
        modifier(PlaybackEnvironmentModifier())
    }
}

private struct PlaybackEnvironmentModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        content.environment(\.playMedia, action)
    }

    private var action: PlayMediaAction {
        #if os(macOS)
        let openWindow = openWindow
        return PlayMediaAction { request in openWindow(id: PlayerScreen.windowID, value: request) }
        #else
        let app = app
        return PlayMediaAction { request in app.presentedPlayback = request }
        #endif
    }
}

/// 线路自动切换 / 全部失联的提示条，3 秒后自动收起。
private struct LineSwitchBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let notice = app.lineRouter.notice {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.isFailure ? "\(notice.serverName) 的所有线路都无法连接" : "\(notice.serverName) 已切换到「\(notice.lineName)」")
                        .font(.subheadline.weight(.semibold))
                    Text(notice.isFailure ? "将继续使用「\(notice.lineName)」，网络恢复后自动重试" : notice.reason.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { app.lineRouter.dismissNotice() }
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled, app.lineRouter.notice?.id == notice.id { app.lineRouter.dismissNotice() }
            }
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
