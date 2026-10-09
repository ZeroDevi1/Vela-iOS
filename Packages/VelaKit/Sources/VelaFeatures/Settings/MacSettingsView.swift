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
                .settingsPage()
            }
            Tab("媒体库", systemImage: "square.stack") { LibrarySettingsView().settingsPage() }
            Tab("播放", systemImage: "play.rectangle") { PlayerSettingsView().settingsPage() }
            Tab("界面", systemImage: "rectangle.inset.filled.and.cursorarrow") { InterfaceSettingsView().settingsPage() }
            Tab("手势", systemImage: "hand.point.up.left") { MacGestureSettingsView().settingsPage() }
            Tab("视频", systemImage: "video") { VideoSettingsView().settingsPage() }
            Tab("音频", systemImage: "headphones") { AudioSettingsView().settingsPage() }
            Tab("字幕", systemImage: "captions.bubble") { SubtitleSettingsView().settingsPage() }
            Tab("连接", systemImage: "link") {
                NavigationStack {
                    Form { ConnectionSections() }
                        .formStyle(.grouped)
                }
                .settingsPage()
            }
        }
        // 固定宽度、足够的高度：各页长短不一，统一尺寸避免切换标签时窗口跳动，长页面在窗口内滚动。
        .frame(width: 680, height: 600)
    }
}

private extension View {
    /// 标签栏所在的工具栏是透明的，默认的柔和滚动边缘效果下，滚上去的内容会透过标签图标显示；
    /// 改为硬边，内容滚到标签栏下方即被截断（与系统设置、SenPlayer 的设置窗口一致）。
    func settingsPage() -> some View {
        scrollEdgeEffectStyle(.hard, for: .top)
    }
}
#endif
