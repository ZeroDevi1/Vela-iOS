import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// 聚合搜索：同时搜索所有非私密服务器，结果按电影 / 剧集 / 单集分类（与 Android 版一致），
/// 按标题与关键词的匹配程度排序（`SearchRanking`）；单个源失败单独提示。
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var query = ""
    @State private var sections: [FederatedSearchSection] = []
    @State private var isSearching = false
    /// 目录源（TMDB / 豆瓣）的结果：不是库条目，进入目录详情后再按 provider id 匹配服务器资源。
    @State private var tmdbResults: Result<[CatalogTitle], any Error>?
    @State private var doubanResults: Result<[DoubanTitle], any Error>?
    /// 类型筛选（至少保留一项）。
    @State private var kinds: Set<SearchKind> = Set(SearchKind.allCases)

    var body: some View {
        HistoryNavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchSuggestionsView()
                } else if isSearching && sections.isEmpty {
                    ProgressView()
                } else if rankedItems.isEmpty, sections.allSatisfy(\.isSuccess), catalogEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    results
                }
            }
            .navigationTitle("搜索")
            .navigationDestination(for: CatalogTitle.self) { CatalogDetailView(title: $0) }
            .navigationDestination(for: DoubanTitle.self) { DoubanResolveView(title: $0) }
            .detailDestinations()
        }
        .searchable(text: $query, prompt: "电影、剧集、单集")
        // 输入联想：已返回结果中最匹配的标题，点按补全为该标题再搜索。
        .searchSuggestions {
            ForEach(completions, id: \.self) { title in
                Label(title, systemImage: "magnifyingglass").searchCompletion(title)
            }
        }
        // 输入停顿 350ms 后再搜索，避免每个字符都打到所有服务器。
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                kindFilter
                ForEach(SearchKind.allCases.filter(kinds.contains), id: \.self) { kind in
                    let items = rankedItems.filter { kind.matches($0) }
                    if !items.isEmpty {
                        MediaShelf("\(kind.title)（\(items.count)）", items: items) { item in
                            NavigationLink(value: item) {
                                PosterCard(
                                    title: item.seriesName ?? item.name,
                                    subtitle: subtitle(for: item),
                                    imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                                    progress: item.playedFraction,
                                    width: layout.posterWidth
                                )
                            }
                            .buttonStyle(.plain)
                            .itemContextMenu(item)
                        }
                    }
                }
                ForEach(sections) { section in
                    if case .failure(let error) = section.result {
                        Label("\(section.sourceName)：\(error.message)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .velaPageMargin()
                    }
                }
                catalogSections
            }
            .padding(.vertical, VelaTheme.Spacing.l)
        }
    }

    /// 类型筛选胶囊（与 Android 版的类型切换一致）。
    private var kindFilter: some View {
        HStack(spacing: VelaTheme.Spacing.s) {
            ForEach(SearchKind.allCases, id: \.self) { kind in
                let selected = kinds.contains(kind)
                Button(kind.title) {
                    if selected {
                        if kinds.count > 1 { kinds.remove(kind) }
                    } else {
                        kinds.insert(kind)
                    }
                }
                .buttonStyle(.bordered)
                .tint(selected ? VelaTheme.accent : nil)
                .fontWeight(selected ? .semibold : .regular)
            }
        }
        .velaPageMargin()
    }

    /// 所有服务器的结果合并后按相关度排序；搜索多台服务器时按服务器顺序保持稳定。
    private var rankedItems: [MediaItem] {
        let all = sections.flatMap { (try? $0.result.get()) ?? [] }
        return SearchRanking.rank(all, query: query) { [$0.name, $0.seriesName] }
    }

    private var completions: [String] {
        var seen: [String] = []
        for title in rankedItems.map({ $0.seriesName ?? $0.name }) where !seen.contains(title) && title != query {
            seen.append(title)
            if seen.count == 6 { break }
        }
        return seen
    }

    /// 年份或集号；搜索了多台服务器时附上来源服务器名。
    private func subtitle(for item: MediaItem) -> String? {
        let base = item.episodeLabel ?? item.productionYear.map(String.init)
        guard sections.count > 1, let source = sections.first(where: { $0.sourceID == item.serverID })?.sourceName else { return base }
        return [base, source].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var catalogSections: some View {
        switch tmdbResults {
        case .success(let titles) where !titles.isEmpty:
            MediaShelf("TMDB（\(titles.count)）", items: titles) { title in
                NavigationLink(value: title) { CatalogPosterCard(title: title) }.buttonStyle(.plain)
            }
        case .failure(let error):
            sourceFailure("TMDB", error)
        default:
            EmptyView()
        }
        switch doubanResults {
        case .success(let titles) where !titles.isEmpty:
            MediaShelf("豆瓣（\(titles.count)）", items: titles) { title in
                NavigationLink(value: title) {
                    PosterCard(
                        title: title.title,
                        subtitle: title.year,
                        imageURL: title.posterURL,
                        width: layout.posterWidth,
                        badges: PosterBadges(rating: title.rating)
                    )
                }
                .buttonStyle(.plain)
            }
        case .failure(let error):
            sourceFailure("豆瓣", error)
        default:
            EmptyView()
        }
    }

    private func sourceFailure(_ name: String, _ error: any Error) -> some View {
        Label("\(name)：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .velaPageMargin()
    }

    private var catalogEmpty: Bool {
        let tmdbEmpty = (try? tmdbResults?.get().isEmpty) ?? true
        let doubanEmpty = (try? doubanResults?.get().isEmpty) ?? true
        return tmdbEmpty && doubanEmpty
    }

    private func search() async {
        let term = query
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            sections = []
            tmdbResults = nil
            doubanResults = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        let tmdb = app.catalog.client
        let subscriptions = app.subscriptions
        async let servers = app.searchService.search(term, in: app.searchableSources)
        async let tmdbTask: Result<[CatalogTitle], any Error>? = tmdb == nil ? nil : await capture { try await tmdb!.search(term) }
        async let doubanTask: Result<[DoubanTitle], any Error>? = subscriptions.isConnected ? await capture { try await subscriptions.searchDouban(term) } : nil
        let (serverResult, tmdbResult, doubanResult) = await (servers, tmdbTask, doubanTask)
        // 期间用户继续输入时丢弃过期结果。
        guard term == query else { return }
        sections = serverResult
        tmdbResults = tmdbResult
        doubanResults = doubanResult
    }
}

private extension FederatedSearchSection {
    var isSuccess: Bool {
        if case .success = result { return true }
        return false
    }
}

/// 搜索结果分类（与 Android `SearchMediaType` 对应）。
private enum SearchKind: CaseIterable, Hashable {
    case movie, series, episode

    var title: String {
        switch self {
        case .movie: "电影"
        case .series: "剧集"
        case .episode: "单集"
        }
    }

    /// 视频 / 音乐视频等归入电影，合集 / 季归入剧集，其余不显示。
    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .movie: [.movie, .video, .musicVideo, .boxSet].contains(item.kind)
        case .series: [.series, .season].contains(item.kind)
        case .episode: item.kind == .episode
        }
    }
}

/// 豆瓣条目 → 目录条目：只按豆瓣返回的 TMDB / IMDb id 换算，不按标题猜测；都没有时提供豆瓣页面链接。
private struct DoubanResolveView: View {
    let title: DoubanTitle
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var resolved: CatalogTitle?
    @State private var failed = false

    var body: some View {
        Group {
            if let resolved {
                CatalogDetailView(title: resolved)
            } else if failed {
                ContentUnavailableView {
                    Label("无法匹配到 TMDB 条目", systemImage: "questionmark.circle")
                } description: {
                    Text("豆瓣没有提供该条目的 TMDB / IMDb id，无法确认它在服务器中对应哪部作品。")
                } actions: {
                    Button("在豆瓣查看") { openURL(URL(string: "https://movie.douban.com/subject/\(title.doubanID)/")!) }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title.title)
        .task(id: title.id) { await resolve() }
    }

    private func resolve() async {
        if let tmdbID = title.tmdbID {
            resolved = CatalogTitle(tmdbID: tmdbID, mediaType: title.mediaType, title: title.title, posterPath: nil,
                                    date: title.year.map { "\($0)-01-01" }, voteAverage: title.rating)
            return
        }
        if let imdb = title.imdbID, let client = app.catalog.client,
           let match = try? await client.find(imdbID: imdb).first(where: { $0.mediaType == title.mediaType }) {
            resolved = match
            return
        }
        failed = true
    }
}

// MARK: - 推荐（未输入时）

/// 未输入关键词时的沉浸式推荐（与 Android 版搜索页一致）：当前服务器随机条目的大海报横向翻页，
/// 背景为当前海报的模糊放大，下方显示标志 / 标题与「★ 评分 • 年份 • 类型」。
///
/// 私密服务器不提供推荐：搜索页是跨服务器入口，不在这里展示私密内容。
private struct SearchSuggestionsView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [MediaItem] = []
    @State private var current: String?
    @State private var hasLoaded = false

    private static let limit = 10

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(proxy.size.width * 0.66, 420)
            let currentItem = items.first { $0.id == current } ?? items.first
            ZStack {
                if let currentItem {
                    background(currentItem)
                }
                if items.isEmpty {
                    if hasLoaded {
                        ContentUnavailableView(
                            "聚合搜索",
                            systemImage: "magnifyingglass",
                            description: Text("同时搜索所有非私密服务器，以及 TMDB（已配置时）与豆瓣（已连接 MoviePilot 时）。")
                        )
                    } else {
                        ProgressView()
                    }
                } else {
                    VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
                        Text("推荐")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(.regularMaterial, in: .capsule)
                            .velaPageMargin()
                        carousel(cardWidth: cardWidth, height: min(cardWidth * 1.5, proxy.size.height * 0.62))
                        if let currentItem {
                            info(currentItem).frame(maxWidth: .infinity)
                        }
                        pageDots.frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, VelaTheme.Spacing.s)
                }
            }
        }
        .task(id: app.servers.activeServer?.id) { await load() }
    }

    private func background(_ item: MediaItem) -> some View {
        CachedImage(url: app.imageURL(for: item, kind: .primary, maxWidth: 400)) { Color.clear }
            .blur(radius: 40)
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: item.id)
            .accessibilityHidden(true)
    }

    private func carousel(cardWidth: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            RemoteArtwork(url: app.imageURL(for: item, kind: .primary, maxWidth: 600))
                                .frame(width: cardWidth, height: height)
                                .clipShape(.rect(cornerRadius: 20))
                                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.name)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, (proxy.size.width - cardWidth) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $current, anchor: .center)
        }
        .frame(height: height)
    }

    private func info(_ item: MediaItem) -> some View {
        VStack(spacing: 8) {
            if let logo = app.client(forServerID: item.serverID)?.logoURL(for: item, maxWidth: 500) {
                CachedImage(url: logo, contentMode: .fit) { Text(item.name).font(.title2.weight(.bold)) }
                    .frame(maxWidth: 220, maxHeight: 60)
            } else {
                Text(item.name).font(.title2.weight(.bold)).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let rating = item.communityRating, rating > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").foregroundStyle(.red)
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                    }
                    Text("•")
                }
                if let year = item.productionYear {
                    Text(String(year))
                    Text("•")
                }
                Text(item.kind == .series ? "剧集" : "电影")
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, VelaTheme.Spacing.l)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let selected = item.id == (current ?? items.first?.id)
                Capsule()
                    .fill(selected ? Color.red : Color.white.opacity(0.35))
                    .frame(width: selected ? 20 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityHidden(true)
    }

    private func load() async {
        defer { hasLoaded = true }
        guard let server = app.servers.activeServer, !server.isPrivate, let client = app.activeClient else {
            items = []
            return
        }
        let page = try? await client.items(ItemQuery(
            includeItemTypes: ["Movie", "Series"],
            recursive: true,
            sortBy: .random,
            limit: Self.limit,
            imageTypes: ["Primary"]
        ))
        items = page?.items ?? []
        current = items.first?.id
    }
}
