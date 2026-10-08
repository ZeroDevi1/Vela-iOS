import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

extension FocusedValues {
    /// macOS「显示 / 隐藏边栏」菜单项作用于当前窗口。
    @Entry var toggleSidebar: (() -> Void)?
}

#if os(macOS)
/// Mac 侧边栏内容（参考 Forward），放在系统 `NavigationSplitView` 的侧边栏栏位，玻璃底与收起按钮由系统提供。
/// 品牌；搜索；服务器（头像列表，点按切换）；浏览（各标签，右侧数量）。
/// 不放「设置」：Mac 用 ⌘,，HIG 不建议把关键操作放在侧边栏底部。
struct SidebarPanel: View {
    @Binding var selection: AppTab
    let counts: SidebarCounts
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
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
            // 滚动内容在顶部品牌处柔和淡出，而不是被硬切。
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
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
        // 选中项用强调色（Mac 跟随系统强调色，HIG 对侧边栏图标颜色的要求）。
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .capsule)
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
#endif
