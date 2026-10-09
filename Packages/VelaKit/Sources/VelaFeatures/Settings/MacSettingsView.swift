#if os(macOS)
import SwiftUI

/// macOS 设置窗口：顶部图标标签、每个标签一页（Mac 设置窗口的标准形式，参考 SenPlayer macOS）。
/// 各页复用 iOS 的设置子页面与分组；含二级页面的标签（通用、连接）自带导航栈。
/// 发现 / 订阅日历在 Mac 侧边栏中，这里不重复入口；触屏手势换为键盘与鼠标设置（`MacGestureSettingsView`）。
///
/// 标签栏自绘（图标 + 文字，选中项强调色），与页面上下排列。窗口尺寸由 Settings 场景的
/// `.windowResizability(.contentSize)` 固定为本视图尺寸，避免窗口比内容矮时顶部被裁掉。
struct MacSettingsView: View {
    @AppStorage("settings.mac.tab") private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
            Divider()
            page(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.title)
        // 固定尺寸：各页长短不一，统一尺寸避免切换标签时窗口跳动，长页面在窗口内滚动。
        .frame(width: 680, height: 620)
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
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
        case .library: LibrarySettingsView()
        case .playback: PlayerSettingsView()
        case .interface: InterfaceSettingsView()
        case .gestures: MacGestureSettingsView()
        case .video: VideoSettingsView()
        case .audio: AudioSettingsView()
        case .subtitles: SubtitleSettingsView()
        case .connections:
            NavigationStack {
                Form { ConnectionSections() }
                    .formStyle(.grouped)
            }
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case general, library, playback, interface, gestures, video, audio, subtitles, connections

    var title: String {
        switch self {
        case .general: "通用"
        case .library: "媒体库"
        case .playback: "播放"
        case .interface: "界面"
        case .gestures: "手势"
        case .video: "视频"
        case .audio: "音频"
        case .subtitles: "字幕"
        case .connections: "连接"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .library: "square.stack"
        case .playback: "play.rectangle"
        case .interface: "rectangle.inset.filled.and.cursorarrow"
        case .gestures: "hand.point.up.left"
        case .video: "video"
        case .audio: "headphones"
        case .subtitles: "captions.bubble"
        case .connections: "link"
        }
    }
}

/// 图标 + 文字的标签按钮行，选中项为强调色并带圆角底色（与系统偏好设置窗口的工具栏标签相同的样子）。
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20))
                            .symbolVariant(selected ? .fill : .none)
                            .frame(height: 24)
                        Text(tab.title).font(.caption)
                    }
                    .frame(width: 64, height: 50)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    )
                    .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
#endif
