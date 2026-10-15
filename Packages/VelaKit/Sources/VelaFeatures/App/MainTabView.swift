import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

public enum AppTab: String, Hashable, Sendable {
    case home, media, favorites, settings, discover, subscriptions, search
}

extension FocusedValues {
    /// 当前窗口的主导航选择；macOS「前往」菜单的快捷键（⌘1… / ⌘F）通过它切换标签。
    @Entry public var selectedTab: Binding<AppTab>?
}

/// 主导航外壳，按平台选择（依据 HIG Tab bars / Sidebars，2026-06 版）：
/// - **iPhone 与 iPad**：系统 `TabView` 底部悬浮 Liquid Glass 标签栏，与 Android 版服务器页底栏一致：
///   首页 / 我的媒体 / 收藏 / 设置 / 搜索。标签栏超过 5 项会折叠出「更多」，发现 / 订阅从设置页「探索」进入。
///   iPad 不用系统顶部标签栏 / 侧边栏，也不再用自绘悬浮面板（第 16 轮用户决定，与 iPhone 一致，参考 SenPlayer）。
/// - **macOS**：`NavigationSplitView` 作容器（系统悬浮玻璃、全高、工具栏排在内容区、可调宽、窗口变窄自动收起），
///   侧边栏栏位放自绘面板内容（第 15 轮 PoC 后定案）。访问过的标签保留在视图树中（隐藏而不移除），
///   切换回来时保留导航栈，与 `TabView` 行为一致。
/// 各页的数据刷新由 `.task(id:)` 按服务器触发，不依赖出现事件。
struct MainTabView: View {
    #if DEBUG
    @MainActor private static var didOpenDebugPlayURL = false
    #endif
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @SceneStorage("selectedTab") private var selection: AppTab = .home
    /// 每个标签各自的导航记录（切换标签不影响其他标签的返回 / 前进）。
    @State private var histories: [AppTab: NavigationHistory] = Dictionary(
        uniqueKeysWithValues: [AppTab.home, .media, .favorites, .settings, .discover, .subscriptions, .search].map { ($0, NavigationHistory()) }
    )
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @State private var visited: Set<AppTab> = []
    @State private var counts = SidebarCounts()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private static let allTabs: [AppTab] = [.home, .media, .favorites, .discover, .subscriptions, .search]
    #endif

    var body: some View {
        shell
            .focusedSceneValue(\.selectedTab, $selection)
            .focusedSceneValue(\.navigationHistory, histories[selection])
            // 恢复到当前平台不存在的标签（macOS 的设置、iOS 的发现 / 订阅）时回到首页。
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
                // macOS 上 `onAppear` 会触发两次，只打开一次播放器。
                if !Self.didOpenDebugPlayURL, let url = environment["VELA_DEBUG_PLAY_URL"].flatMap(URL.init(string:)) {
                    Self.didOpenDebugPlayURL = true
                    playMedia(PlaybackRequest(target: .url(url), title: url.lastPathComponent))
                }
                #endif
            }
            #if os(macOS)
            .onChange(of: selection, initial: true) { _, tab in visited.insert(tab) }
            // 切换服务器或标签时刷新侧边栏数量（例如在详情页收藏后回到侧边栏）。
            .task(id: CountsKey(server: app.servers.activeServer?.id, accessible: app.isActiveServerAccessible, tab: selection)) {
                // 私密服务器未解锁时不在侧边栏透露内容数量（与 `PrivacyGate` 一致）。
                guard app.isActiveServerAccessible, let client = app.activeClient else {
                    counts = SidebarCounts()
                    return
                }
                counts = await SidebarCounts.load(client: client)
            }
            #endif
    }

    #if os(iOS)
    /// 底部标签栏，下滑时收起。数量不显示为角标（标签栏会画成红色通知角标，含义不对）。
    ///
    /// iPad 常规宽度下系统 `TabView` 会把标签栏画在顶部：对 `TabView` 声明紧凑宽度让它画成底部悬浮标签栏，
    /// 各页再恢复真实的宽度档（详情页宽屏版式、播放器面板等依赖它）。
    private var shell: some View {
        // 无网络时只保留首页（显示已下载内容）与设置，与 Android 版一致。
        let online = app.network.isOnline
        return TabView(selection: $selection) {
            Tab("首页", systemImage: "house", value: AppTab.home) { page(.home) }
            if online {
                Tab("我的媒体", systemImage: "play.square.stack", value: AppTab.media) { page(.media) }
                Tab("收藏", systemImage: "heart", value: AppTab.favorites) { page(.favorites) }
            }
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) { page(.settings) }
            if online {
                Tab(value: AppTab.search, role: .search) { page(.search) }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(\.horizontalSizeClass, .compact)
        .onChange(of: online) { _, isOnline in
            if !isOnline, selection != .home, selection != .settings { selection = .home }
        }
    }
    #else
    /// 系统侧边栏容器 + 自绘内容。系统在工具栏提供显示 / 隐藏边栏按钮，各页不再画自己的边栏按钮。
    private var shell: some View {
        let toggle = {
            withAnimation(.snappy) { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
        }
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarPanel(selection: $selection, counts: counts)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            tabs
        }
        .focusedSceneValue(\.toggleSidebar, toggle)
    }

    /// 访问过的标签叠放在一起，只显示当前标签；未访问的不创建（避免启动时加载所有页面）。
    private var tabs: some View {
        ZStack {
            ForEach(Self.allTabs.filter { visited.contains($0) && isAvailable($0) }, id: \.self) { tab in
                let isCurrent = tab == selection
                page(tab)
                    .opacity(isCurrent ? 1 : 0)
                    .allowsHitTesting(isCurrent)
                    .accessibilityHidden(!isCurrent)
                    .zIndex(isCurrent ? 1 : 0)
            }
        }
    }

    private struct CountsKey: Hashable {
        var server: SavedServer.ID?
        var accessible: Bool
        var tab: AppTab
    }
    #endif

    @ViewBuilder
    private func page(_ tab: AppTab) -> some View {
        #if os(iOS)
        pageContent(tab).environment(\.horizontalSizeClass, sizeClass).environment(histories[tab])
        #else
        pageContent(tab).environment(histories[tab])
        #endif
    }

    @ViewBuilder
    private func pageContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: PrivacyGate { HomeView() }.measuresVelaLayout()
        case .media: PrivacyGate { MyMediaView() }.measuresVelaLayout()
        case .favorites: PrivacyGate { FavoritesView() }.measuresVelaLayout()
        case .discover: DiscoverView().measuresVelaLayout()
        case .subscriptions: SubscriptionsView().measuresVelaLayout()
        case .search: PrivacyGate { SearchView() }.measuresVelaLayout()
        case .settings: SettingsView()
        }
    }

    private func isAvailable(_ tab: AppTab) -> Bool {
        switch tab {
        case .settings:
            #if os(iOS)
            true
            #else
            false
            #endif
        case .discover, .subscriptions:
            #if os(iOS)
            false
            #else
            true
            #endif
        default: true
        }
    }
}
