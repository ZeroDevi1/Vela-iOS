import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 首页分区的「查看全部」。
enum HomeListRoute: Hashable {
    case resume, nextUp, favorites, downloads

    var title: String {
        switch self {
        case .resume: "继续观看"
        case .nextUp: "接下来播放"
        case .favorites: "我的收藏"
        case .downloads: "下载"
        }
    }
}

/// 分页网格：继续观看 / 接下来播放用横版卡，收藏用海报。滚动到末尾时加载下一页。
struct HomeListView: View {
    let route: HomeListRoute
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedOnce = false

    private static let pageSize = 40

    private var usesLandscape: Bool { route != .favorites }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: VelaTheme.Spacing.l) {
                ForEach(items) { item in
                    NavigationLink(value: item) { card(item) }
                        .buttonStyle(.plain)
                        .itemContextMenu(item)
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
            if loadedOnce, items.isEmpty, error == nil {
                ContentUnavailableView(
                    route == .favorites ? "还没有收藏" : "暂无内容",
                    systemImage: route == .favorites ? "heart" : "film.stack"
                )
            }
        }
        .navigationTitle(route.title)
        .refreshableLoad { await reload() }
        .task(id: app.servers.activeServer?.baseURL) { await reload() }
    }

    /// 横版卡宽度：iPhone 竖屏一行两张。
    private var landscapeWidth: CGFloat { isCompact ? 170 : 260 }

    private var columns: [GridItem] {
        let minimum = usesLandscape ? landscapeWidth : layout.posterWidth
        return [GridItem(.adaptive(minimum: minimum), spacing: VelaTheme.Spacing.m, alignment: .top)]
    }

    @ViewBuilder
    private func card(_ item: MediaItem) -> some View {
        if usesLandscape {
            let image = item.kind == .episode
                ? app.imageURL(for: item, kind: .primary, maxWidth: 640)
                : app.imageURL(for: item, kind: .backdrop, maxWidth: 640)
            LandscapeCard(
                title: item.seriesName ?? item.name,
                subtitle: HomeView.episodeSubtitle(item),
                imageURL: image ?? app.imageURL(for: item, kind: .primary, maxWidth: 640),
                progress: item.playedFraction,
                width: landscapeWidth,
                caption: HomeView.remainingCaption(item)
            )
        } else {
            PosterCard(
                title: item.kind == .episode ? (item.seriesName ?? item.name) : item.name,
                subtitle: item.kind == .episode ? HomeView.episodeSubtitle(item) : item.productionYear.map(String.init),
                imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                width: layout.posterWidth,
                badges: PosterBadges(item)
            )
        }
    }

    private func reload() async {
        items = []
        total = 0
        error = nil
        await loadMore()
        loadedOnce = true
    }

    private func loadMore() async {
        guard !isLoading, items.isEmpty || items.count < total, let client = app.activeClient else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(client: client, startIndex: items.count)
            items.append(contentsOf: page.items)
            total = page.total
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetch(client: MediaServerClient, startIndex: Int) async throws -> (items: [MediaItem], total: Int) {
        switch route {
        case .resume:
            try await client.resume(limit: Self.pageSize, startIndex: startIndex)
        case .nextUp:
            try await client.nextUpPage(limit: Self.pageSize, startIndex: startIndex)
        case .downloads:
            ([], 0)
        case .favorites:
            try await client.items(ItemQuery(
                includeItemTypes: ["Movie", "Series", "Episode", "BoxSet"],
                recursive: true,
                sortBy: .name,
                startIndex: startIndex,
                limit: Self.pageSize,
                isFavorite: true
            ))
        }
    }
}
