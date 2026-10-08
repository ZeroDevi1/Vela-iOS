import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 侧边栏的显示状态与开关，经环境传给各标签根页面（面板收起时在导航栏左侧显示开关按钮）。
struct SidebarControl {
    /// 面板当前是否显示。
    var isVisible = false
    /// 宽屏停靠（面板常驻左侧、内容让出宽度）；否则以模态形式盖在内容上。
    var isDocked = false
    var toggle: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var sidebarControl = SidebarControl()
}

extension FocusedValues {
    /// macOS「显示 / 隐藏边栏」菜单项作用于当前窗口。
    @Entry var toggleSidebar: (() -> Void)?
}

/// 标签根页面导航栏左侧的「边栏」按钮：面板已显示时不出现（面板顶部自带收起按钮）。
/// 须加在 `NavigationStack` 内的根内容上，推入的子页面不显示。
struct SidebarToggleItem: ToolbarContent {
    @Environment(\.sidebarControl) private var sidebar

    var body: some ToolbarContent {
        if !sidebar.isVisible {
            ToolbarItem(placement: .navigation) {
                Button("显示边栏", systemImage: "sidebar.left", action: sidebar.toggle)
            }
        }
    }
}

/// 侧边栏面板（参考 Forward）：悬浮的 Liquid Glass 圆角面板，背景内容透出。
/// 顶部收起按钮与品牌；搜索；服务器（头像列表，点按切换）；浏览（各标签，右侧数量）；底部设置。
struct SidebarPanel: View {
    @Binding var selection: AppTab
    let counts: SidebarCounts
    let close: () -> Void
    @Environment(AppModel.self) private var app

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("收起边栏", systemImage: "sidebar.left", action: close)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.plain)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image("VelaMark", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    Text("Vela").font(.title3.weight(.bold))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    item(.search, "搜索", "magnifyingglass")
                        .padding(.top, 10)

                    if !app.servers.servers.isEmpty {
                        sectionTitle("服务器")
                        ForEach(app.servers.servers) { server in
                            SidebarServerRow(server: server, isActive: server.id == app.servers.activeServer?.id) {
                                app.servers.activate(server.id)
                            }
                        }
                    }

                    sectionTitle("浏览")
                    item(.home, "首页", "house", count: counts.resume)
                    item(.media, "我的媒体", "play.square.stack", count: counts.libraries)
                    item(.favorites, "收藏", "heart", count: counts.favorites)
                    item(.discover, "发现", "safari")
                    item(.subscriptions, "订阅", "calendar")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            Divider().padding(.horizontal, 20)
            settingsRow
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private func item(_ tab: AppTab, _ title: String, _ symbol: String, count: Int? = nil) -> some View {
        SidebarRow(title: title, symbol: symbol, count: count, isSelected: selection == tab) {
            selection = tab
        }
    }

    @ViewBuilder
    private var settingsRow: some View {
        #if os(macOS)
        // macOS 的设置是独立的 Settings 场景。
        SettingsLink {
            SidebarRowLabel(title: "设置", symbol: "gearshape", count: nil, isSelected: false)
        }
        .buttonStyle(.plain)
        #else
        SidebarRow(title: "设置", symbol: "gearshape", count: nil, isSelected: selection == .settings) {
            selection = .settings
        }
        #endif
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(title: title, symbol: symbol, count: count, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarRowLabel: View {
    let title: String
    let symbol: String
    let count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
            Text(title).font(.body.weight(isSelected ? .semibold : .regular))
            Spacer(minLength: 0)
            // 数量只在大于 0 时显示（灰色数字，参考 Forward「在看 78」）。
            if let count, count > 0 {
                Text(count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .capsule)
        .contentShape(.capsule)
    }
}

private struct SidebarServerRow: View {
    let server: SavedServer
    let isActive: Bool
    let activate: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 12) {
                CachedImage(url: app.client(forServerID: server.id)?.userImageURL) {
                    ZStack {
                        Circle().fill(VelaTheme.accent.opacity(0.25))
                        Text(server.displayName.prefix(1)).font(.headline).foregroundStyle(VelaTheme.accent)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(.circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.displayName).font(.body.weight(isActive ? .semibold : .regular)).lineLimit(1)
                    Text(isActive ? "当前服务器" : server.kind.displayName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if server.isPrivate {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isActive ? "" : "切换到该服务器")
    }
}

/// 侧边栏条目右侧的数量：继续观看、媒体库、收藏。单项请求失败时该项不显示（nil），不影响其他项。
struct SidebarCounts {
    var resume: Int?
    var libraries: Int?
    var favorites: Int?

    static func load(client: MediaServerClient) async -> SidebarCounts {
        async let resume = try? client.resume(limit: 1).total
        async let libraries = try? client.userViews().count
        async let favorites = try? client.items(ItemQuery(
            includeItemTypes: ["Movie", "Series", "Episode"], recursive: true, limit: 1, isFavorite: true
        )).total
        return await SidebarCounts(resume: resume, libraries: libraries, favorites: favorites)
    }
}
