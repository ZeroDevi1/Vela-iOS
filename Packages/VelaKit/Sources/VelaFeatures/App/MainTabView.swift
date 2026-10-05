import SwiftUI

enum AppTab: String, Hashable {
    case home, media, favorites, settings, discover, subscriptions, search
}

/// 主导航，与 Android 版服务器页的底栏一致：首页 / 我的媒体 / 搜索 / 收藏 / 设置。
///
/// `sidebarAdaptable`：iPhone 为底部 Liquid Glass 标签栏，iPad / Mac 可展开为侧边栏。
/// 「发现」「订阅」只在宽屏（iPad / Mac）显示为标签；紧凑宽度下标签栏超过 5 项会折叠出「更多」并挤掉搜索，
/// 因此 iPhone 从设置页进入。
struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("selectedTab") private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "house", value: AppTab.home) {
                PrivacyGate { HomeView() }
            }
            Tab("我的媒体", systemImage: "play", value: AppTab.media) {
                PrivacyGate { MyMediaView() }
            }
            Tab("收藏", systemImage: "heart", value: AppTab.favorites) {
                PrivacyGate { FavoritesView() }
            }
            #if os(iOS)
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            #endif
            if sizeClass != .compact {
                Tab("发现", systemImage: "safari", value: AppTab.discover) {
                    DiscoverView()
                }
                Tab("订阅", systemImage: "calendar", value: AppTab.subscriptions) {
                    SubscriptionsView()
                }
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        // 恢复到当前布局中不存在的标签（macOS 的设置、紧凑宽度下的发现 / 订阅）时回到首页。
        .onAppear { if !isAvailable(selection) { selection = .home } }
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
