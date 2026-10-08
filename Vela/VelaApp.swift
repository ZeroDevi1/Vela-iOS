import SwiftUI
import VelaFeatures

/// 应用入口：只负责 Scene 组织与依赖创建，业务代码在 VelaKit 包中。
@main
struct VelaApp: App {
    @State private var app = AppModel()
    #if os(iOS)
    /// 播放器横竖屏锁定需要由 App 代理返回当前允许的方向。
    @UIApplicationDelegateAdaptor(VelaAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            VelaRootView()
                .environment(app)
                #if os(macOS)
                // 侧边栏约 220pt + 内容区至少 compact 档的一屏海报；再窄会挤压侧边栏与卡片。
                .frame(minWidth: 800, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            VelaCommands()
            PlayerCommands()
        }
        #endif

        #if os(macOS)
        // macOS 播放器使用独立窗口，可与浏览窗口并排、单独全屏。
        WindowGroup("播放器", id: PlayerScreen.windowID, for: PlaybackRequest.self) { $request in
            if let request {
                PlayerScreen(request: request)
                    .environment(app)
            }
        }
        .windowStyle(.hiddenTitleBar)
        // 不恢复上次退出时开着的播放器窗口：否则下次启动会自动重新起播（还会写入服务器播放记录）。
        .restorationBehavior(.disabled)
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(app)
                .velaPlaybackEnvironment()
                .frame(minWidth: 480, minHeight: 420)
        }
        #endif
    }
}
