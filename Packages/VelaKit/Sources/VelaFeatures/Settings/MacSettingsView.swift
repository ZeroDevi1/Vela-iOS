#if os(macOS)
import SwiftUI

/// macOS 设置窗口：顶部图标标签、每个标签一页（Mac 设置窗口的标准形式，参考 SenPlayer macOS）。
/// 各页复用 iOS 的设置子页面与分组；含二级页面的标签（通用、连接）自带导航栈。
/// 发现 / 订阅日历在 Mac 侧边栏中，这里不重复入口；触屏手势换为键盘与鼠标设置（`MacGestureSettingsView`）。
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") {
                NavigationStack {
                    Form {
                        ServersSection()
                        Section("本机能力") { CapabilityRows() }
                        StorageSection()
                        PrivacySection()
                        DebugPlaybackSection()
                        AboutSection()
                    }
                    .formStyle(.grouped)
                    .serverEditDestination()
                }
            }
            Tab("媒体库", systemImage: "square.stack") { LibrarySettingsView() }
            Tab("播放", systemImage: "play.rectangle") { PlayerSettingsView() }
            Tab("界面", systemImage: "rectangle.inset.filled.and.cursorarrow") { InterfaceSettingsView() }
            Tab("手势", systemImage: "hand.point.up.left") { MacGestureSettingsView() }
            Tab("视频", systemImage: "video") { VideoSettingsView() }
            Tab("音频", systemImage: "headphones") { AudioSettingsView() }
            Tab("字幕", systemImage: "captions.bubble") { SubtitleSettingsView() }
            Tab("连接", systemImage: "link") {
                NavigationStack {
                    Form { ConnectionSections() }
                        .formStyle(.grouped)
                }
            }
        }
        // 固定宽度、足够的高度：各页长短不一，统一尺寸避免切换标签时窗口跳动，长页面在窗口内滚动。
        .frame(width: 680, height: 600)
    }
}
#endif
