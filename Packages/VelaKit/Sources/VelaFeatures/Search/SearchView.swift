import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 当前服务器内搜索（与 Android 版进入服务器后的搜索页一致）：按选中的类型请求服务器，
/// 结果按标题与关键词的匹配程度排序（`SearchRanking`），分为电影 / 剧集横排海报与单集列表。
/// 未输入关键词时显示推荐大海报。
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.velaLayout) private var layout
    @State private var query = ""
    /// nil：尚未搜索或关键词为空；`.failure` 时整页显示错误。
    @State private var results: Result<[MediaItem], any Error>?
    /// 类型筛选（至少保留一项）。
    @State private var kinds: Set<SearchKind> = Set(SearchKind.allCases)
    /// 推荐放在这里而不是推荐视图内：清空关键词回到推荐时保持同一批条目与翻页位置。nil 为加载中。
    @State private var suggestions: [MediaItem]?
    /// 推荐翻页的虚拟页号（见 `SearchSuggestionsView.pageCount`），条目为 `suggestions[page % count]`。
    @State private var suggestionPage: Int?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        HistoryNavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    SearchSuggestionsView(items: suggestions, page: $suggestionPage)
                } else {
                    switch results {
                    case .failure(let error):
                        ContentUnavailableView("搜索失败", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
                    case .success(let items) where !items.isEmpty:
                        resultList(items)
                    case .success:
                        ContentUnavailableView.search(text: query)
                    case nil:
                        // 刚输入、防抖等待或首次请求中。
                        ProgressView()
                    }
                }
            }
            .navigationTitle(app.servers.activeServer?.displayName ?? "搜索")
            .navigationDestination(for: SearchCategoryRoute.self) { SearchCategoryView(route: $0) }
            .detailDestinations()
        }
        .searchable(text: $query, prompt: "电影、剧集、单集")
        // 输入联想：已返回结果中最匹配的标题，点按补全为该标题再搜索。
        .searchSuggestions {
            ForEach(completions, id: \.self) { title in
                Label(title, systemImage: "magnifyingglass").searchCompletion(title)
            }
        }
        // 输入停顿 300ms 后再搜索（与 Android 一致）；切换类型或服务器时重新搜索。
        .task(id: SearchKey(query: trimmedQuery, kinds: kinds, serverID: app.servers.activeServer?.id)) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
        .task(id: app.servers.activeServer?.id) { await loadSuggestions() }
    }

    private func resultList(_ items: [MediaItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                kindFilter
                ForEach(SearchKind.allCases.filter(kinds.contains), id: \.self) { kind in
                    let matched = Array(items.filter { kind.matches($0) }.prefix(kind.limit))
                    if !matched.isEmpty {
                        if kind == .episode {
                            episodeSection(matched)
                        } else {
                            MediaShelf(kind.title, items: matched) { item in
                                NavigationLink(value: item) {
                                    PosterCard(
                                        title: item.name,
                                        subtitle: item.productionYear.map(String.init),
                                        imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                                        progress: item.playedFraction,
                                        width: layout.posterWidth
                                    )
                                }
                                .buttonStyle(.plain)
                                .itemContextMenu(item)
                            } accessory: {
                                viewAllLink(kind)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, VelaTheme.Spacing.l)
        }
    }

    /// 单集为纵向列表：缩略图 + 剧名 + 集号与单集标题（与 Android `EpisodeResultCard` 一致）。
    private func episodeSection(_ episodes: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(SearchKind.episode.title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: VelaTheme.Spacing.s)
                viewAllLink(.episode)
            }
            ForEach(episodes) { episode in
                NavigationLink(value: episode) {
                    HStack(spacing: VelaTheme.Spacing.m) {
                        RemoteArtwork(url: app.imageURL(for: episode, kind: .primary, maxWidth: 320), placeholderSymbol: "tv")
                            .frame(width: 107, height: 60)
                            .clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.seriesName ?? episode.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text([episode.episodeLabel, episode.seriesName == nil ? nil : episode.name]
                                .compactMap { $0 }
                                .joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .itemContextMenu(episode)
            }
        }
        .velaPageMargin()
    }

    /// 分区标题右侧的「查看全部」：进入该类型的完整搜索结果（分页、可排序，与 Android `onNavigateToSearchCategory` 一致）。
    @ViewBuilder
    private func viewAllLink(_ kind: SearchKind) -> some View {
        if let serverID = app.servers.activeServer?.id {
            NavigationLink(value: SearchCategoryRoute(serverID: serverID, query: trimmedQuery, kind: kind)) {
                ShelfViewAllArrow()
            }
            .buttonStyle(.plain)
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

    private var completions: [String] {
        guard case .success(let items) = results else { return [] }
        var seen: [String] = []
        for title in items.map({ $0.seriesName ?? $0.name }) where !seen.contains(title) && title != query {
            seen.append(title)
            if seen.count == 6 { break }
        }
        return seen
    }

    /// 服务器推荐（与 Android `getSuggestions(mediaType = "Movie,Series", limit = 15)` 相同）。
    /// 推荐接口报错（旧版服务器未实现）或返回为空（新服务器尚无观看记录）时，改取随机电影 / 剧集，避免整页空白；
    /// 两者都失败时显示「暂无推荐」。
    private func loadSuggestions() async {
        suggestions = nil
        guard let client = app.activeClient else {
            suggestions = []
            return
        }
        var items = (try? await client.suggestions(types: ["Movie", "Series"], limit: 15)) ?? []
        if items.isEmpty, !Task.isCancelled {
            items = (try? await client.items(ItemQuery(
                includeItemTypes: ["Movie", "Series"],
                recursive: true,
                sortBy: .random,
                limit: 15,
                imageTypes: ["Primary"]
            )).items) ?? []
        }
        guard !Task.isCancelled else { return }
        suggestions = items
        suggestionPage = SearchSuggestionsView.initialPage(count: items.count)
    }

    private func search() async {
        let term = trimmedQuery
        guard !term.isEmpty, let client = app.activeClient else {
            results = nil
            return
        }
        let selected = SearchKind.allCases.filter(kinds.contains)
        let outcome: Result<[MediaItem], any Error>
        do {
            let page = try await client.items(ItemQuery(
                searchTerm: term,
                includeItemTypes: selected.map(\.serverType),
                recursive: true,
                limit: 60
            ))
            outcome = .success(SearchRanking.rank(page.items, query: term) { [$0.name, $0.seriesName] })
        } catch is CancellationError {
            return
        } catch {
            outcome = .failure(error)
        }
        // 期间用户继续输入或切换类型时丢弃过期结果。
        guard !Task.isCancelled, term == trimmedQuery else { return }
        results = outcome
    }
}

private struct SearchKey: Hashable {
    var query: String
    var kinds: Set<SearchKind>
    var serverID: String?
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

    /// 请求服务器时的 `IncludeItemTypes`。
    var serverType: String {
        switch self {
        case .movie: "Movie"
        case .series: "Series"
        case .episode: "Episode"
        }
    }

    /// 每类最多显示的条数（与 Android `resultsFor` 一致）。
    var limit: Int { self == .episode ? 40 : 20 }

    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .movie: item.kind == .movie
        case .series: item.kind == .series
        case .episode: item.kind == .episode
        }
    }
}

// MARK: - 查看全部

private struct SearchCategoryRoute: Hashable {
    var serverID: String
    var query: String
    var kind: SearchKind
}

/// 某一类型的完整搜索结果：服务器分页、可排序（与 Android 搜索分类进入的「查看全部」一致）。
/// 不再按标题相关度过滤，列出服务器认为匹配的全部条目（包括只命中原标题、简介的）。
private struct SearchCategoryView: View {
    let route: SearchCategoryRoute
    @State private var sort = LibrarySort(field: .name, descending: false)

    var body: some View {
        PagedItemGrid(
            serverID: route.serverID,
            template: ItemQuery(searchTerm: route.query, includeItemTypes: [route.kind.serverType], recursive: true),
            sort: sort,
            played: nil,
            style: route.kind == .episode ? .landscape : .poster,
            counts: nil
        ) {
            EmptyView()
        }
        .navigationTitle("\(route.kind.title)：\(route.query)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                LibrarySortMenu(options: LibrarySort.fields(for: route.kind == .series ? "tvshows" : nil), sort: $sort)
            }
        }
    }
}

// MARK: - 推荐（未输入时）

/// 未输入关键词时的沉浸式推荐（与 Android `SuggestionsStoriesView` 一致）：当前服务器推荐电影 / 剧集的大海报横向翻页，
/// 首尾相接可无限循环；两侧海报缩小、半透明并带 3D 倾斜；背景为当前海报铺满加暗角，下方显示标志与「★ 评分 • 年份 • 类型」。
private struct SearchSuggestionsView: View {
    /// nil 为加载中。
    let items: [MediaItem]?
    /// 当前虚拟页号；nil 时视为 `initialPage`。
    @Binding var page: Int?
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact

    /// 每个条目重复的轮数。循环做法与 Android 相同：把条目铺成一长串虚拟页、从中间开始，页号取模得到条目；
    /// 1000 轮即每个方向约 500 × 条目数页，手动翻页翻不到头，而 LazyHStack 只创建可见的几页。
    private static let rounds = 1000

    static func pageCount(count: Int) -> Int { count <= 1 ? count : count * rounds }

    /// 位于中间、且对齐到第一个条目的页号。
    static func initialPage(count: Int) -> Int { count <= 1 ? 0 : count * (rounds / 2) }

    private func index(of page: Int, count: Int) -> Int { count == 0 ? 0 : page % count }

    var body: some View {
        GeometryReader { proxy in
            // 手机卡片宽 280pt，宽屏固定 320pt（Android `SuggestionsCard` / 平板 `tabletPageWidth`）。
            let cardWidth: CGFloat = isCompact ? min(280, proxy.size.width - 96) : 320
            let items = items ?? []
            let currentPage = page ?? Self.initialPage(count: items.count)
            let currentItem = items.isEmpty ? nil : items[index(of: currentPage, count: items.count)]
            ZStack {
                Color.homeBackground.ignoresSafeArea()
                if let currentItem {
                    background(currentItem)
                }
                if items.isEmpty {
                    if self.items != nil {
                        ContentUnavailableView(
                            "暂无推荐",
                            systemImage: "magnifyingglass",
                            description: Text("在当前服务器中搜索电影、剧集与单集。")
                        )
                    } else {
                        ProgressView()
                    }
                } else {
                    VStack(spacing: VelaTheme.Spacing.l) {
                        // 选中态胶囊：与页面背景反色（深色模式白底黑字，浅色模式黑底白字）。
                        Text("推荐")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.homeBackground)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.primary, in: .capsule)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .velaPageMargin()
                        Spacer(minLength: 0)
                        carousel(items, cardWidth: cardWidth, height: min(cardWidth / 0.67, proxy.size.height * 0.6))
                        if let currentItem {
                            info(currentItem)
                        }
                        pageDots(count: items.count)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, VelaTheme.Spacing.s)
                }
            }
        }
    }

    /// 当前海报铺满背景，再叠向页面背景色过渡的暗角与自上而下的渐变（与 Android 相同的透明度，颜色跟随浅色 / 深色模式）。
    /// 海报放在 `Color.clear` 的 overlay 里并裁切：直接以填充模式铺开时，竖版海报在横屏宽屏上会按宽度放大，
    /// 把 ZStack 撑得远高于屏幕，内容随之被挤出可视区。
    private func background(_ item: MediaItem) -> some View {
        let base = Color.homeBackground
        return Color.clear
            .overlay {
                CachedImage(url: app.imageURL(for: item, kind: .primary, maxWidth: 800)) { Color.clear }
            }
            .clipped()
            .overlay(
                RadialGradient(
                    colors: [base.opacity(0.3), base.opacity(0.6), base.opacity(0.9)],
                    center: .center, startRadius: 0, endRadius: 600
                )
            )
            .overlay(LinearGradient(colors: [.clear, base.opacity(0.2), base.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: item.id)
            .accessibilityHidden(true)
    }

    private func carousel(_ items: [MediaItem], cardWidth: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 16) {
                    ForEach(0..<Self.pageCount(count: items.count), id: \.self) { slot in
                        let item = items[index(of: slot, count: items.count)]
                        NavigationLink(value: item) {
                            RemoteArtwork(url: app.imageURL(for: item, kind: .primary, maxWidth: 600))
                                .frame(width: cardWidth, height: height)
                                .overlay(Color.black.opacity(0.2))
                                .clipShape(.rect(cornerRadius: 20))
                                .shadow(color: .black.opacity(0.5), radius: slot == page ? 12 : 6, y: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.name)
                        // 偏离中心的卡片缩小到 0.85、透明度 0.6，并绕 Y 轴倾斜（Android `graphicsLayer` 的 rotationY = 偏移 × 25°）。
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(1 - 0.15 * min(abs(phase.value), 1))
                                .opacity(1 - 0.4 * min(abs(phase.value), 1))
                                .rotation3DEffect(.degrees(phase.value * 25), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max((proxy.size.width - cardWidth) / 2, 0), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page, anchor: .center)
        }
        .frame(height: height)
    }

    private func info(_ item: MediaItem) -> some View {
        VStack(spacing: 12) {
            Group {
                if let logo = app.client(forServerID: item.serverID)?.logoURL(for: item, maxWidth: 400) {
                    CachedImage(url: logo, contentMode: .fit) { Text(item.name).font(.title3.weight(.bold)) }
                        .frame(maxWidth: 180, maxHeight: 40)
                } else {
                    Text(item.name).font(.title3.weight(.bold)).lineLimit(1)
                }
            }
            .frame(height: 40)
            Text(metaLine(item))
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 32)
    }

    /// 「★ 评分 • 年份 • 类型」，星号为红色（Android `0xFFFF4D4F`）。
    private func metaLine(_ item: MediaItem) -> AttributedString {
        var parts: [AttributedString] = []
        if let rating = item.communityRating, rating > 0 {
            var star = AttributedString("★ ")
            star.foregroundColor = Color(red: 1, green: 0.302, blue: 0.31)
            parts.append(star + AttributedString(rating.formatted(.number.precision(.fractionLength(1)))))
        }
        if let year = item.productionYear {
            parts.append(AttributedString(String(year)))
        }
        parts.append(AttributedString(item.kind == .series ? "剧集" : "电影"))
        return parts.dropFirst().reduce(parts[0]) { $0 + AttributedString("  •  ") + $1 }
    }

    /// 循环翻页没有首尾，指示器与 Android 相同：最多 7 个圆点，红色长条固定在正中，越靠两侧越小越淡。
    private func pageDots(count: Int) -> some View {
        let visible = min(count, 7)
        let center = visible / 2
        return HStack(spacing: 7) {
            ForEach(0..<visible, id: \.self) { slot in
                let distance = abs(slot - center)
                Capsule()
                    .fill(distance == 0 ? Color.red : Color.primary.opacity(distance == 1 ? 0.32 : 0.24))
                    .frame(width: distance == 0 ? 16 : (distance == 1 ? 8 : 6), height: 6)
            }
        }
        .opacity(count > 1 ? 1 : 0)
        .accessibilityHidden(true)
    }
}
