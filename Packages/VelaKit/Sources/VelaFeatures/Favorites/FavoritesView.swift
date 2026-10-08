import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 收藏：与 Android 版一致按 电影 / 剧集 / 单集 分区，分区标题右侧「→」进入完整网格。
struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var favorites: LoadState<[MediaItem]> = .idle

    /// 首屏取的收藏数量；超过时在完整网格中分页查看。
    private static let limit = 200

    var body: some View {
        NavigationStack {
            Group {
                switch favorites {
                case .loaded(let items) where items.isEmpty:
                    ContentUnavailableView("还没有收藏", systemImage: "heart", description: Text("在详情页点击心形即可收藏。"))
                case .loaded(let items):
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                            shelf("电影", items.filter { $0.kind == .movie })
                            shelf("剧集", items.filter { $0.kind == .series })
                            episodeShelf(items.filter { $0.kind == .episode })
                        }
                        .padding(.vertical, VelaTheme.Spacing.l)
                    }
                case .failed(let message):
                    LoadFailureView(message: message) { Task { await load() } }
                case .idle, .loading:
                    ProgressView()
                }
            }
            .navigationTitle("收藏")
            .toolbar { SidebarToggleItem() }
            .navigationDestination(for: HomeListRoute.self) { HomeListView(route: $0) }
            .detailDestinations()
            .refreshable { await load() }
            .task(id: app.servers.activeServer?.baseURL) { await load() }
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ items: [MediaItem]) -> some View {
        if !items.isEmpty {
            MediaShelf(title, items: items) { item in
                NavigationLink(value: item) {
                    PosterCard(
                        title: item.name,
                        subtitle: item.productionYear.map(String.init),
                        imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                        width: layout.posterWidth,
                        badges: PosterBadges(item)
                    )
                }
                .buttonStyle(.plain)
            } accessory: {
                NavigationLink(value: HomeListRoute.favorites) { ShelfViewAllArrow() }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func episodeShelf(_ items: [MediaItem]) -> some View {
        if !items.isEmpty {
            MediaShelf("单集", items: items) { item in
                NavigationLink(value: item) {
                    LandscapeCard(
                        title: item.seriesName ?? item.name,
                        subtitle: HomeView.episodeSubtitle(item),
                        imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 640),
                        progress: item.playedFraction,
                        width: HomeView.landscapeWidth(compact: isCompact)
                    )
                }
                .buttonStyle(.plain)
            } accessory: {
                NavigationLink(value: HomeListRoute.favorites) { ShelfViewAllArrow() }.buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        guard let client = app.activeClient else {
            favorites = .failed("无法连接当前服务器，请在设置中检查服务器与登录状态。")
            return
        }
        if favorites.value == nil { favorites = .loading }
        favorites = LoadState(await capture {
            try await client.items(ItemQuery(
                includeItemTypes: ["Movie", "Series", "Episode"],
                recursive: true,
                sortBy: .name,
                limit: Self.limit,
                isFavorite: true
            )).items
        })
    }
}
