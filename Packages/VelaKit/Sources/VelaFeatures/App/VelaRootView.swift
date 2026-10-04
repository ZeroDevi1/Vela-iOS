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
