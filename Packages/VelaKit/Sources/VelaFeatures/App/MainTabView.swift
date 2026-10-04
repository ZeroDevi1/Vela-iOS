import SwiftUI

enum AppTab: Hashable {
    case home, discover, library, subscriptions, search
}

/// 主导航。`sidebarAdaptable`：iPhone 为底部 Liquid Glass 标签栏，iPad / Mac 可展开为侧边栏。
struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @SceneStorage("selectedTab") private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "house", value: AppTab.home) {
                PrivacyGate { HomeView() }
            }
            Tab("发现", systemImage: "safari", value: AppTab.discover) {
                DiscoverView()
            }
            Tab("媒体库", systemImage: "square.stack", value: AppTab.library) {
                PrivacyGate { LibraryView() }
            }
            Tab("订阅", systemImage: "calendar", value: AppTab.subscriptions) {
                SubscriptionsView()
            }
            // 设置不占标签：iPhone 标签栏超过 5 项会折叠出「更多」，并把搜索挤进去。
            // iOS 通过首页 / 媒体库右上角齿轮进入，macOS 使用系统「设置」窗口（⌘,）。
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }
}

extension AppTab: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "discover": self = .discover
        case "library": self = .library
        case "subscriptions": self = .subscriptions
        case "search": self = .search
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .discover: "discover"
        case .library: "library"
        case .subscriptions: "subscriptions"
        case .search: "search"
        }
    }
}
