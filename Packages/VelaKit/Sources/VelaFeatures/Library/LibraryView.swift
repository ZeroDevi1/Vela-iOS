import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 媒体库入口：列出服务器上的库（电影 / 剧集 / 合集等）。
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var views: LoadState<[MediaItem]> = .idle

    var body: some View {
        NavigationStack {
            Group {
                switch views {
                case .loaded(let items) where items.isEmpty:
                    ContentUnavailableView("没有媒体库", systemImage: "square.stack")
                case .loaded(let items):
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 160 : 240), spacing: VelaTheme.Spacing.m)],
                                  spacing: VelaTheme.Spacing.l) {
                            ForEach(items) { library in
                                NavigationLink(value: LibraryRoute(library: library)) {
                                    LandscapeCard(
                                        title: library.name,
                                        subtitle: nil,
                                        imageURL: app.imageURL(for: library, kind: .primary, maxWidth: 600),
                                        width: isCompact ? 160 : 240
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(VelaTheme.Spacing.l)
                    }
                case .failed(let message):
                    LoadFailureView(message: message) { Task { await load() } }
                default:
                    ProgressView()
                }
            }
            .navigationTitle("媒体库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ServerSwitcherMenu() }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
                #endif
            }
            .navigationDestination(for: LibraryRoute.self) { LibraryItemsView(library: $0.library) }
            .detailDestinations()
            .task(id: app.servers.activeServer?.baseURL) { await load() }
        }
    }

    private func load() async {
        guard let client = app.activeClient else { return }
        views = .loading
        views = LoadState(await capture { try await client.userViews() })
    }
}

struct LibraryRoute: Hashable {
    var library: MediaItem
}

/// 库内条目网格，滚动到末尾时分页加载。
struct LibraryItemsView: View {
    let library: MediaItem
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var sort: ItemQuery.SortField = .dateCreated

    private static let pageSize = 60

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: VelaTheme.posterWidth(compact: isCompact)), spacing: VelaTheme.Spacing.m)],
                spacing: VelaTheme.Spacing.l
            ) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCard(
                            title: item.name,
                            subtitle: item.productionYear.map(String.init),
                            imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                            progress: item.playedFraction,
                            width: VelaTheme.posterWidth(compact: isCompact)
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
                }
            }
            .padding(VelaTheme.Spacing.l)

            if isLoading { ProgressView().padding() }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle(library.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("排序", systemImage: "arrow.up.arrow.down", selection: $sort) {
                    Text("最近添加").tag(ItemQuery.SortField.dateCreated)
                    Text("名称").tag(ItemQuery.SortField.name)
                    Text("上映日期").tag(ItemQuery.SortField.premiereDate)
                    Text("评分").tag(ItemQuery.SortField.communityRating)
                }
                .pickerStyle(.menu)
            }
        }
        .task(id: sort) {
            items = []
            total = 0
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !isLoading, items.isEmpty || items.count < total, let client = app.client(forServerID: library.serverID) else { return }
        isLoading = true
        defer { isLoading = false }
        let query = ItemQuery(
            parentID: library.id,
            includeItemTypes: ["Movie", "Series", "Video", "BoxSet"],
            recursive: true,
            sortBy: sort,
            sortDescending: sort != .name,
            startIndex: items.count,
            limit: Self.pageSize
        )
        do {
            let page = try await client.items(query)
            items.append(contentsOf: page.items)
            total = page.total
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
