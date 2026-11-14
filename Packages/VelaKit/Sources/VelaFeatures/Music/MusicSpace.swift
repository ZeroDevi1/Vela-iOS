import SwiftUI
import VelaCore
import VelaDesignSystem

/// 音乐与影视共享服务器切换入口；曲库导航随账号隔离。
struct MusicSpace: View {
    let server: SavedServer
    @Environment(AppModel.self) private var app
    @State private var selection: MusicTab = .home
    @State private var source: MusicSource?
    @State private var connectionError: String?
    @State private var retry = 0
    @State private var isPlayerOpen = false
    @State private var isQueueOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        ZStack {
            shell
                .allowsHitTesting(!isPlayerOpen)
                .accessibilityHidden(isPlayerOpen)
            if isPlayerOpen, showsPlayer {
                MusicPlaybackPage(onClose: { showPlayer(false) }, onQueue: openQueue)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $isQueueOpen) {
            MusicQueueSheet()
        }
        .task(id: LoadKey(server: server, unlocked: app.isActiveServerAccessible, retry: retry)) {
            source = nil
            connectionError = nil
            guard app.isActiveServerAccessible else { return }
            do {
                source = try await app.musicSource(for: server)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                connectionError = error.localizedDescription
            }
        }
        .onChange(of: showsPlayer) { _, available in
            if !available {
                isPlayerOpen = false
                isQueueOpen = false
            }
        }
    }

    private struct LoadKey: Equatable {
        var server: SavedServer
        var unlocked: Bool
        var retry: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.server.id == rhs.server.id && lhs.server.baseURL == rhs.server.baseURL
                && lhs.server.isPrivate == rhs.server.isPrivate && lhs.unlocked == rhs.unlocked && lhs.retry == rhs.retry
        }
    }

    #if os(iOS)
    private var shell: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: MusicTab.home.symbol, value: .home) { page(.home) }
            Tab("曲库", systemImage: MusicTab.library.symbol, value: .library) { page(.library) }
            Tab("我的", systemImage: MusicTab.mine.symbol, value: .mine) { page(.mine) }
            Tab("设置", systemImage: MusicTab.settings.symbol, value: .settings) { page(.settings) }
            Tab(value: MusicTab.search, role: .search) { page(.search) }
        }
        .tabViewBottomAccessory(isEnabled: showsPlayer) { miniPlayer }
        .environment(\.horizontalSizeClass, .compact)
    }
    #else
    private var shell: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(MusicTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .navigationTitle("音乐")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            page(selection)
                .id(selection)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsPlayer { miniPlayer.background(.bar) }
                }
        }
    }
    #endif

    private var showsPlayer: Bool {
        app.isActiveServerAccessible && app.music.source?.id == server.id && app.music.current != nil
    }

    private var miniPlayer: some View {
        MusicMiniPlayer(onOpen: { showPlayer(true) }, onQueue: openQueue)
    }

    private func showPlayer(_ open: Bool) {
        guard !open || showsPlayer else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            isPlayerOpen = open
        }
    }

    private func openQueue() {
        if showsPlayer { isQueueOpen = true }
    }

    @ViewBuilder
    private func page(_ tab: MusicTab) -> some View {
        NavigationStack {
            Group {
                if tab == .settings {
                    Form {
                        ServersSection()
                        if app.isActiveServerAccessible, let source { MusicServerSection(source: source) }
                        PrivacySection()
                        AboutSection()
                    }
                    .formStyle(.grouped)
                    .serverEditDestination()
                } else {
                    PrivacyGate {
                        if let source {
                            content(tab, source: source)
                                .navigationDestination(for: MusicRoute.self) { route in
                                    MusicDetailPage(route: route, source: source)
                                }
                        } else if let connectionError {
                            MusicLoadError(message: connectionError) { retry += 1 }
                        } else {
                            ProgressView("正在连接音乐库")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(tab.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(tab == .home ? .large : .inline)
            #endif
            .toolbar {
                if tab != .settings { ToolbarItem(placement: .primaryAction) { ServerSwitcherMenu() } }
            }
        }
        #if os(iOS)
        .environment(\.horizontalSizeClass, sizeClass)
        #endif
    }

    @ViewBuilder
    private func content(_ tab: MusicTab, source: MusicSource) -> some View {
        switch tab {
        case .home:
            MusicHomePage(source: source,
                          openLibrary: { selection = .library },
                          openPlayer: { showPlayer(true) })
        case .library:
            MusicLibraryPage(source: source)
        case .mine:
            MusicMyPage(source: source)
        case .search:
            MusicSearchPage(source: source)
        case .settings:
            EmptyView()
        }
    }
}

private enum MusicTab: String, CaseIterable, Identifiable {
    case home, library, mine, settings, search
    var id: Self { self }
    var title: String {
        switch self {
        case .home: "音乐"
        case .library: "曲库"
        case .mine: "我的"
        case .settings: "设置"
        case .search: "搜索"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "music.note.list"
        case .mine: "heart"
        case .settings: "gearshape"
        case .search: "magnifyingglass"
        }
    }
}
