import SwiftUI
import VelaCore
import VelaDesignSystem

public enum AppTab: String, Hashable, Sendable {
    case home, media, favorites, settings, discover, subscriptions, search
}

extension FocusedValues {
    /// 当前窗口的主导航选择；macOS「前往」菜单的快捷键（⌘1… / ⌘F）通过它切换标签。
    @Entry public var selectedTab: Binding<AppTab>?
}

/// 主导航，与 Android 版服务器页的底栏一致：首页 / 我的媒体 / 搜索 / 收藏 / 设置。
///
/// `sidebarAdaptable`：iPhone 为底部 Liquid Glass 标签栏，iPad / Mac 可展开为侧边栏（收起时为顶部胶囊标签栏）。
/// 侧边栏参考 Forward：顶部是品牌标识与服务器列表（点按切换），Mac 底部为设置入口。
/// 「发现」「订阅」只在宽屏（iPad / Mac）显示为标签；紧凑宽度下标签栏超过 5 项会折叠出「更多」并挤掉搜索，
/// 因此 iPhone 从设置页进入。
struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.playMedia) private var playMedia
    @SceneStorage("selectedTab") private var selection: AppTab = .home

    var body: some View {
        // 不用 TabSection 分组：iPad 侧边栏收起后，顶部胶囊栏会只显示分组名（「媒体」「探索」），
        // 首页 / 我的媒体等无法一键直达；保持扁平，分组感由侧边栏头部的品牌与服务器列表提供。
        TabView(selection: $selection) {
            Tab("首页", systemImage: "house", value: AppTab.home) {
                PrivacyGate { HomeView() }.measuresVelaLayout()
            }
            Tab("我的媒体", systemImage: "play.square.stack", value: AppTab.media) {
                PrivacyGate { MyMediaView() }.measuresVelaLayout()
            }
            Tab("收藏", systemImage: "heart", value: AppTab.favorites) {
                PrivacyGate { FavoritesView() }.measuresVelaLayout()
            }
            if sizeClass != .compact {
                Tab("发现", systemImage: "safari", value: AppTab.discover) {
                    DiscoverView().measuresVelaLayout()
                }
                Tab("订阅", systemImage: "calendar", value: AppTab.subscriptions) {
                    SubscriptionsView().measuresVelaLayout()
                }
            }
            #if os(iOS)
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            #endif
            Tab(value: AppTab.search, role: .search) {
                SearchView().measuresVelaLayout()
            }
        }
        .tabViewSidebarHeader { SidebarHeader() }
        .focusedSceneValue(\.selectedTab, $selection)
        #if os(macOS)
        // macOS 的设置是独立的 Settings 场景，不是标签：放在侧边栏底部（Forward 的「设置」位置）。
        .tabViewSidebarBottomBar {
            SettingsLink {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, VelaTheme.Spacing.m)
            .padding(.vertical, VelaTheme.Spacing.s)
        }
        #endif
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        // 恢复到当前布局中不存在的标签（macOS 的设置、紧凑宽度下的发现 / 订阅）时回到首页。
        .onAppear {
            if !isAvailable(selection) { selection = .home }
            #if DEBUG
            // 仅 Debug：`VELA_DEBUG_TAB=<AppTab>` 指定启动标签；`VELA_DEBUG_OPEN_ITEM` 由首页处理
            // （见 `HomeView.openDebugLaunchItem`），需先切到首页。用于真机命令行启动后截图验收。
            let environment = ProcessInfo.processInfo.environment
            if let tab = environment["VELA_DEBUG_TAB"].flatMap(AppTab.init(rawValue:)), isAvailable(tab) {
                selection = tab
            } else if environment["VELA_DEBUG_OPEN_ITEM"] != nil {
                selection = .home
            }
            // `VELA_DEBUG_PLAY_URL`：直接播放该地址（可配合 `VELA_DEBUG_ENGINE` 指定内核），
            // 用公开测试片源验证内核，不触碰服务器上的播放记录。
            if let url = environment["VELA_DEBUG_PLAY_URL"].flatMap(URL.init(string:)) {
                playMedia(PlaybackRequest(target: .url(url), title: url.lastPathComponent))
            }
            #endif
        }
        .onChange(of: sizeClass) { if !isAvailable(selection) { selection = .home } }
    }

    private func isAvailable(_ tab: AppTab) -> Bool {
        switch tab {
        case .settings:
            #if os(iOS)
            true
            #else
            false
            #endif
        case .discover, .subscriptions: sizeClass != .compact
        default: true
        }
    }
}

/// 侧边栏顶部：品牌标识，下面是已登录的服务器（头像、名称、当前服务器打勾），点按即切换。
/// 对应 Forward 侧边栏顶部的「发现」头像列表；服务器较多时整个侧边栏滚动，不单独限高。
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            HStack(spacing: VelaTheme.Spacing.s) {
                Image("VelaMark", bundle: .main)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("Vela").font(.title2.weight(.bold))
            }
            .padding(.bottom, VelaTheme.Spacing.xs)

            if !app.servers.servers.isEmpty {
                Text("服务器").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(app.servers.servers) { server in
                        ServerRow(server: server, isActive: server.id == app.servers.activeServer?.id) {
                            app.servers.activate(server.id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, VelaTheme.Spacing.s)
    }
}

private struct ServerRow: View {
    let server: SavedServer
    let isActive: Bool
    let activate: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        Button(action: activate) {
            HStack(spacing: VelaTheme.Spacing.m) {
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
            .padding(.horizontal, VelaTheme.Spacing.s)
            .padding(.vertical, 6)
            .background(isActive ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isActive ? "" : "切换到该服务器")
    }
}
