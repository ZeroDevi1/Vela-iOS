import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 「我的媒体」顶部的发现入口（与 Android 版「发现」页的三个分页一致）。
enum DiscoverFeed: String, CaseIterable, Hashable, Identifiable {
    case recommendations, watched, awards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommendations: "为你推荐"
        case .watched: "已观看"
        case .awards: "获奖作品"
        }
    }

    var symbol: String {
        switch self {
        case .recommendations: "sparkles"
        case .watched: "checkmark.circle"
        case .awards: "trophy"
        }
    }
}

/// 一行入口按钮，点按进入对应的发现分页。
struct DiscoverFeedEntries: View {
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: VelaTheme.Spacing.s) {
                ForEach(DiscoverFeed.allCases) { feed in
                    NavigationLink(value: feed) {
                        Label(feed.title, systemImage: feed.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(.regularMaterial, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .velaHorizontalPaging()
    }
}

struct DiscoverFeedView: View {
    let feed: DiscoverFeed

    var body: some View {
        switch feed {
        case .recommendations: RecommendationsFeedView()
        case .watched: WatchedFeedView()
        case .awards: AwardsFeedView()
        }
    }
}

/// 服务器的电影推荐（按每个电影库请求后同名分组合并）；没有推荐时提示多看几部后再来。
private struct RecommendationsFeedView: View {
    @Environment(AppModel.self) private var app
    @State private var groups: LoadState<[MediaRecommendation]> = .idle

    var body: some View {
        FeedShelves(state: groups.map { $0.map { ($0.title ?? "", $0.items) } }, emptyText: "看过或收藏几部电影后，这里会出现相似推荐。") {
            await load()
        }
        .navigationTitle("为你推荐")
        .task(id: app.servers.activeServer?.id) { await load() }
    }

    private func load() async {
        guard let client = app.activeClient else {
            groups = .failed("无法连接当前服务器")
            return
        }
        if groups.value == nil { groups = .loading }
        let result = await capture {
            let libraries = try await client.userViews().filter { $0.collectionType == "movies" }
            // 没有识别出电影库时不限定父级，由服务器在全部库中推荐。
            let parents: [String?] = libraries.isEmpty ? [nil] : libraries.map(\.id)
            var all: [MediaRecommendation] = []
            for parent in parents {
                all += try await client.movieRecommendations(parentID: parent)
            }
            return MediaRecommendation.merged(all)
        }
        groups = LoadState(result)
    }
}

/// 已看过的电影、剧集与单集（按最近播放排序），与 Android 版「已观看」分页一致。
private struct WatchedFeedView: View {
    @Environment(AppModel.self) private var app
    @State private var shelves: LoadState<[(String, [MediaItem])]> = .idle

    var body: some View {
        FeedShelves(state: shelves, emptyText: "还没有看完的电影或剧集。") { await load() }
            .navigationTitle("已观看")
            .task(id: app.servers.activeServer?.id) { await load() }
    }

    private func load() async {
        guard let client = app.activeClient else {
            shelves = .failed("无法连接当前服务器")
            return
        }
        if shelves.value == nil { shelves = .loading }
        let result = await capture {
            async let movies = client.items(Self.query(["Movie"])).items
            async let episodes = client.items(Self.query(["Episode"])).items
            let (watchedMovies, watchedEpisodes) = try await (movies, episodes)
            // 剧集按单集的最近播放顺序列出（服务器不直接给「已看剧集」的播放时间）。
            var seriesIDs: [String] = []
            for id in watchedEpisodes.compactMap(\.seriesID) where !seriesIDs.contains(id) { seriesIDs.append(id) }
            var series: [MediaItem] = []
            for id in seriesIDs.prefix(Self.limit) {
                if let item = try? await client.item(id: id) { series.append(item) }
            }
            return [("电影", watchedMovies), ("剧集", series), ("单集", watchedEpisodes)].filter { !$0.1.isEmpty }
        }
        shelves = LoadState(result)
    }

    nonisolated private static let limit = 30

    nonisolated private static func query(_ types: [String]) -> ItemQuery {
        ItemQuery(includeItemTypes: types, recursive: true, sortBy: .datePlayed, sortDescending: true, limit: limit, isPlayed: true)
    }
}

/// 分组横滑列表 + 加载 / 失败 / 空状态。
struct FeedShelves: View {
    let state: LoadState<[(String, [MediaItem])]>
    let emptyText: String
    let reload: () async -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.velaLayout) private var layout

    var body: some View {
        switch state {
        case .loaded(let shelves) where shelves.isEmpty:
            ContentUnavailableView("暂无内容", systemImage: "sparkles", description: Text(emptyText))
        case .loaded(let shelves):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                    ForEach(shelves.indices, id: \.self) { index in
                        let (title, items) = shelves[index]
                        MediaShelf(title, items: items) { item in
                            NavigationLink(value: item) {
                                PosterCard(
                                    title: item.seriesName ?? item.name,
                                    subtitle: item.episodeLabel ?? item.productionYear.map(String.init),
                                    imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                                    progress: item.playedFraction,
                                    width: layout.posterWidth
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, VelaTheme.Spacing.l)
            }
            .refreshable { await reload() }
        case .failed(let message):
            LoadFailureView(message: message) { Task { await reload() } }
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension LoadState {
    /// 转换已加载的值，保留加载 / 失败状态。
    func map<T>(_ transform: (Value) -> T) -> LoadState<T> {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case .loaded(let value): .loaded(transform(value))
        case .failed(let message): .failed(message)
        }
    }
}

/// 获奖作品（与 Android 版「奖项」分页一致）：按 Wikidata 的获奖 / 提名记录列出作品，TMDB 补全标题与海报，
/// 点按进入目录详情（再按 provider id 匹配服务器资源）。需要配置 TMDB。
private struct AwardsFeedView: View {
    @Environment(AppModel.self) private var app
    @State private var awardID = AwardsCatalog.awards[0].id
    @State private var rows: LoadState<[AwardRow]> = .idle

    struct AwardRow: Identifiable {
        var id: String
        var title: String
        var titles: [CatalogTitle]
    }

    /// 每行补全的作品数：每部要请求一次 TMDB。
    nonisolated private static let perRow = 12

    var body: some View {
        Group {
            if app.catalog.client == nil {
                ContentUnavailableView("需要 TMDB", systemImage: "trophy",
                                       description: Text("获奖作品的标题与海报来自 TMDB，请先在设置中填写 TMDB API Key。"))
            } else {
                content
            }
        }
        .navigationTitle("获奖作品")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("奖项", selection: $awardID) {
                    ForEach(AwardsCatalog.awards) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu)
            }
        }
        .task(id: awardID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch rows {
        case .loaded(let rows) where rows.isEmpty:
            ContentUnavailableView("暂无数据", systemImage: "trophy", description: Text("Wikidata 中没有找到该奖项带 TMDB 信息的作品。"))
        case .loaded(let rows):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                    ForEach(rows) { row in
                        MediaShelf(row.title, items: row.titles) { title in
                            NavigationLink(value: title) { CatalogPosterCard(title: title) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, VelaTheme.Spacing.l)
            }
        case .failed(let message):
            LoadFailureView(message: message) { Task { await load() } }
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard let tmdb = app.catalog.client,
              let award = AwardsCatalog.awards.first(where: { $0.id == awardID }) else { return }
        rows = .loading
        let result = await capture {
            let wikidata = WikidataAwardsClient.shared
            let headline = award.categories[0]
            async let winners = wikidata.titles(categories: award.categories.map(\.qid), mode: .winners)
            async let nominees = wikidata.titles(categories: [headline.qid], mode: .nominees)
            let (winnerRefs, nomineeRefs) = try await (winners, nominees)
            // 行的顺序与 Android 一致：头奖得主、头奖提名、其余类别得主。
            var plan: [(String, String, [AwardTitleRef])] = [("winners", "\(headline.label) · 获奖", winnerRefs[headline.qid] ?? [])]
            plan.append(("nominees", "\(headline.label) · 提名", nomineeRefs[headline.qid] ?? []))
            for category in award.categories.dropFirst() {
                plan.append((category.qid, category.label, winnerRefs[category.qid] ?? []))
            }
            var built: [AwardRow] = []
            for (id, title, refs) in plan where !refs.isEmpty {
                let titles = await Self.hydrate(Array(refs.prefix(Self.perRow)), tmdb: tmdb)
                if !titles.isEmpty { built.append(AwardRow(id: id, title: title, titles: titles)) }
            }
            return built
        }
        guard awardID == award.id else { return }
        rows = LoadState(result)
    }

    /// 并发向 TMDB 补全标题与海报（单部失败时跳过），保持引用顺序。
    nonisolated private static func hydrate(_ refs: [AwardTitleRef], tmdb: TMDBClient) async -> [CatalogTitle] {
        await withTaskGroup(of: (Int, CatalogTitle?).self) { group in
            for (index, ref) in refs.enumerated() {
                group.addTask { (index, try? await tmdb.title(ref.mediaType, id: ref.tmdbID)) }
            }
            var resolved = [CatalogTitle?](repeating: nil, count: refs.count)
            for await (index, title) in group { resolved[index] = title }
            return resolved.compactMap { $0 }
        }
    }
}
