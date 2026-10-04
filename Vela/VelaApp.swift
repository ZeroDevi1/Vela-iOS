import SwiftUI
import VelaFeatures

/// 应用入口：只负责 Scene 组织与依赖创建，业务代码在 VelaKit 包中。
@main
struct VelaApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            VelaRootView()
                .environment(app)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
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
