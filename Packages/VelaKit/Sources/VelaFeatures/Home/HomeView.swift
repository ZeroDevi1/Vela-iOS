import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork
#if os(iOS)
import AVKit
#endif

/// 当前服务器首页，布局与 Android 版一致：
/// 顶部栏（分类 / 线路 / 投屏 / 头像）→ 卡片轮播 → 媒体库 → 继续观看 → 接下来 → 各库「最近添加」。
/// 「电影」「剧集」分类下，轮播之后改为按风格分区。
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @Environment(\.playMedia) private var playMedia
    @State private var model = HomeModel()
    @SceneStorage("home.category") private var category: HomeModel.Category = .home
    /// `MainTabView` 按标签注入；调试启动参数据此推入详情页。
    @Environment(NavigationHistory.self) private var history: NavigationHistory?

    var body: some View {
        if app.network.isOnline {
            onlineBody
        } else {
            // 无网络：首页回退到已下载内容（与 Android 版一致），恢复联网后自动回到服务器首页。
            NavigationStack { DownloadsView(isOffline: true) }
        }
    }

    private var onlineBody: some View {
        HistoryNavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                    #if os(iOS)
                    // 与 Android 版一致：顶部栏属于轮播区，随内容滚走，不遮挡下方分区。
                    HomeTopBar(category: $category)
                    #endif
                    let featured = featuredItems
                    if prefs.showHero, !featured.isEmpty {
                        HomeCarousel(items: featured, compact: isCompact, layout: layout, style: prefs.heroStyle, size: prefs.heroSize)
                    }
                    if category == .home {
                        homeContent
                    } else {
                        genreContent
                    }
                }
                .padding(.bottom, VelaTheme.Spacing.l)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            // Mac 用窗口工具栏承载分类与服务器操作（原生位置），不在内容里画浮动按钮。
            .toolbar { HomeToolbar(category: $category) }
            #endif
            .navigationTitle(app.servers.activeServer?.displayName ?? "首页")
            .navigationDestination(for: HomeListRoute.self) { route in
                if route == .downloads { DownloadsView() } else { HomeListView(route: route) }
            }
            .navigationDestination(for: LibraryRoute.self) { LibraryItemsView(library: $0.library, initialSort: $0.initialSort, mixedContentView: app.libraryPreferences.mixedContentView) }
            .navigationDestination(for: GenreRoute.self) { GenreItemsView(route: $0) }
            .detailDestinations()
            .refreshableLoad { await load() }
            .task(id: app.servers.activeServer?.baseURL) { await load() }
            .task(id: TaskKey(category: category, server: app.servers.activeServer?.baseURL)) {
                guard let client = app.activeClient else { return }
                await model.loadGenres(category, client: client)
            }
            #if DEBUG
            .task(id: app.servers.activeServer?.baseURL) { await openDebugLaunchItem() }
            #endif
        }
    }

    #if DEBUG
    /// 仅 Debug 构建：启动环境变量 `VELA_DEBUG_OPEN_ITEM=<名称>` 时，在当前服务器搜索该名称并直接推入第一个结果的详情页。
    /// 真机无法注入点击，用于命令行启动后截图验收详情页版式（`devicectl device process launch --environment-variables`）。
    private func openDebugLaunchItem() async {
        guard let history, history.path.isEmpty,
              let term = ProcessInfo.processInfo.environment["VELA_DEBUG_OPEN_ITEM"], !term.isEmpty,
              let client = app.activeClient else { return }
        let query = ItemQuery(searchTerm: term, includeItemTypes: ["Movie", "Series", "Episode"], recursive: true, limit: 1)
        if let item = try? await client.items(query).items.first {
            history.push(item)
        }
    }
    #endif

    private struct TaskKey: Hashable {
        var category: HomeModel.Category
        var server: URL?
    }

    private var prefs: LibraryPreferences { app.libraryPreferences }

    /// 分类下轮播只显示对应类型；没有对应类型时退回全部，避免轮播消失。
    private var featuredItems: [MediaItem] {
        let kind: MediaItem.Kind? = switch category {
        case .home: nil
        case .movies: .movie
        case .tvShows: .series
        }
        let featured = unwatched(model.featured)
        guard let kind else { return featured }
        let filtered = featured.filter { $0.kind == kind }
        return filtered.isEmpty ? featured : filtered
    }

    /// 「隐藏已观看项目」：首页的轮播与最近添加 / 风格分区去掉已看完的条目（剧集看完全部才算）。
    private func unwatched(_ items: [MediaItem]) -> [MediaItem] {
        prefs.hideWatched ? items.filter { !$0.isPlayed } : items
    }

    // MARK: - 首页分类

    @ViewBuilder
    private var homeContent: some View {
        if !model.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }

        if prefs.showMyMedia, !model.libraries.isEmpty {
            MediaShelf("媒体库", items: model.libraries) { library in
                NavigationLink(value: LibraryRoute(library: library)) {
                    LandscapeCard(
                        title: library.name,
                        subtitle: nil,
                        imageURL: app.imageURL(for: library, kind: .primary, maxWidth: 600),
                        width: Self.landscapeWidth(compact: isCompact)
                    )
                }
                .buttonStyle(.plain)
            }
        }

        if prefs.showResume, !model.resume.isEmpty {
            MediaShelf("继续观看", items: model.resume) { item in
                NavigationLink(value: item) { resumeCard(item) }.buttonStyle(.plain).itemContextMenu(item)
            } accessory: {
                NavigationLink(value: HomeListRoute.resume) { ShelfCountLabel(count: model.resumeTotal) }
                    .buttonStyle(.plain)
            }
        }

        if prefs.showNextUp, !model.nextUp.isEmpty {
            MediaShelf("接下来", items: model.nextUp) { item in
                NavigationLink(value: item) { resumeCard(item) }.buttonStyle(.plain).itemContextMenu(item)
            } accessory: {
                NavigationLink(value: HomeListRoute.nextUp) { ShelfCountLabel(count: model.nextUpTotal) }
                    .buttonStyle(.plain)
            }
        }

        ForEach(model.shelves) { shelf in
            MediaShelf("最近添加-\(shelf.library.name)", items: unwatched(shelf.items)) { item in
                NavigationLink(value: item) { posterCard(item) }.buttonStyle(.plain).itemContextMenu(item)
            } accessory: {
                // 从「最近添加」进入时临时按添加日期倒序，与分区含义一致。
                NavigationLink(value: LibraryRoute(library: shelf.library, initialSort: LibrarySort(field: .dateCreated, descending: true))) {
                    ShelfViewAllArrow()
                }
                    .buttonStyle(.plain)
            }
        }

        failureLabels

        if model.isEmpty {
            ContentUnavailableView("暂无内容", systemImage: "film.stack", description: Text("服务器上还没有可展示的内容。"))
        }
    }

    @ViewBuilder
    private var failureLabels: some View {
        ForEach(model.failures.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
            Label("\(name)加载失败：\(message)", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .velaPageMargin()
        }
    }

    // MARK: - 电影 / 剧集分类

    @ViewBuilder
    private var genreContent: some View {
        switch model.genreShelves[category] {
        case .loaded(let shelves) where shelves.isEmpty:
            ContentUnavailableView("暂无\(category.title)", systemImage: "film.stack")
        case .loaded(let shelves):
            ForEach(shelves) { shelf in
                MediaShelf(shelf.genre.name, items: unwatched(shelf.items)) { item in
                    NavigationLink(value: item) { posterCard(item) }.buttonStyle(.plain).itemContextMenu(item)
                } accessory: {
                    if let type = category.itemType {
                        NavigationLink(value: GenreRoute(genre: shelf.genre, itemType: type)) { ShelfViewAllArrow() }
                            .buttonStyle(.plain)
                    }
                }
            }
        case .failed(let message):
            Label("\(category.title)加载失败：\(message)", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .velaPageMargin()
        case .idle, .loading, nil:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    // MARK: - 卡片

    private func posterCard(_ item: MediaItem) -> some View {
        PosterCard(
            title: item.name,
            subtitle: item.productionYear.map(String.init),
            imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
            width: layout.posterWidth,
            badges: PosterBadges(item)
        )
    }

    /// 继续观看 / 接下来卡片；右上角显示剩余时长。
    /// 图片：「使用“集”图片」开启时单集用自己的截图，否则用剧集横版图（Thumb → Backdrop）。
    private func resumeCard(_ item: MediaItem) -> some View {
        let episodeImage = prefs.useEpisodeImages && item.kind == .episode
            ? app.imageURL(for: item, kind: .primary, maxWidth: 640) : nil
        let image = episodeImage
            ?? app.imageURL(for: item, kind: .thumb, maxWidth: 640)
            ?? app.imageURL(for: item, kind: .backdrop, maxWidth: 640)
            ?? app.imageURL(for: item, kind: .primary, maxWidth: 640)
        let width = Self.landscapeWidth(compact: isCompact)
        return LandscapeCard(
            title: item.seriesName ?? item.name,
            subtitle: Self.episodeSubtitle(item),
            imageURL: image,
            progress: item.playedFraction,
            width: width,
            caption: Self.remainingCaption(item)
        )
        // 「显示播放按钮」：点按直接续播，不进入详情页。
        .overlay(alignment: .top) {
            if prefs.showPlayButton {
                Button {
                    playMedia(.item(item))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .frame(height: width * 9 / 16)
                .accessibilityLabel("播放 \(item.seriesName ?? item.name)")
            }
        }
    }

    /// 首页横版卡宽度：iPhone 一屏约两张（与 Android 版 200dp 卡片比例一致）。
    static func landscapeWidth(compact: Bool) -> CGFloat { compact ? 190 : 280 }

    /// 「S01 E05 - 英雄」；非单集为年份。
    static func episodeSubtitle(_ item: MediaItem) -> String? {
        guard item.kind == .episode else { return item.productionYear.map(String.init) }
        let season = item.parentIndexNumber.map { String(format: "S%02d", $0) }
        let episode = item.indexNumber.map { String(format: "E%02d", $0) }
        let number = [season, episode].compactMap { $0 }.joined(separator: " ")
        return number.isEmpty ? item.name : "\(number) - \(item.name)"
    }

    /// 「剩余 15 分钟」「剩余 1 小时 5 分钟」；没有进度或已看完时为 nil。
    static func remainingCaption(_ item: MediaItem) -> String? {
        guard let position = item.playbackPositionTicks, position > 0,
              let total = item.runTimeTicks, total > position else { return nil }
        let minutes = max(1, Int((Ticks.seconds(total - position) / 60).rounded()))
        return minutes >= 60 ? "剩余 \(minutes / 60) 小时 \(minutes % 60) 分钟" : "剩余 \(minutes) 分钟"
    }

    private func load() async {
        guard let client = app.activeClient else { return }
        await model.load(client: client)
    }
}

extension PosterBadges {
    /// 剧集显示未看集数，电影显示已看勾，右下角社区评分；各角标可在「媒体库配置 → 海报偏好」中关闭。
    init(_ item: MediaItem) {
        self.init(
            unplayedCount: item.kind == .series ? item.unplayedItemCount : nil,
            isPlayed: item.kind != .series && item.isPlayed,
            rating: item.communityRating,
            versionCount: item.versionCount
        )
    }
}

// MARK: - 风格条目

/// 首页「电影」「剧集」分类中某个风格的全部条目。
struct GenreRoute: Hashable {
    var genre: MediaItem
    var itemType: String
}

private struct GenreItemsView: View {
    let route: GenreRoute
    @State private var sort = LibrarySort(field: .dateCreated, descending: true)

    var body: some View {
        var template = ItemQuery(includeItemTypes: [route.itemType], recursive: true)
        template.genreIDs = [route.genre.id]
        return PagedItemGrid(serverID: route.genre.serverID, template: template, sort: sort, played: nil)
            .navigationTitle(route.genre.name)
    }
}

// MARK: - 轮播

/// 卡片式轮播（Android 版「紧凑」样式）：当前卡片居中、两侧露出相邻卡片，8 秒自动翻页，首尾相接循环。
/// 不用 `TabView(.page)`：macOS 不支持，且无法露出相邻卡片。
///
/// 循环：条目重复三份，从中间一份开始；滚动停下后若落在首尾两份，无动画地跳回中间一份的同一条目，
/// 因此第一张左侧也有卡片，末尾翻到开头也只滑一格。
/// 当前卡片按可见度判断（完全可见的那一张），不用 `scrollPosition(id:)` 的回写：动画滚动途中它会写入经过的卡片，
/// 自动翻页以此为起点会一次跳过好几张。拖动期间不自动翻页。
///
/// 宽屏（`VelaLayout.isWide`）且选择「背景图」样式时改为沉浸式大头图（与宽屏详情页头图同风格）：
/// 每页铺满宽度、无间隙与圆角，左下为 Logo、元数据与两行简介，循环与自动翻页逻辑不变。
/// 「海报」样式保持卡片轮播，尊重用户设置。
private struct HomeCarousel: View {
    let items: [MediaItem]
    let compact: Bool
    let layout: VelaLayout
    /// 海报（竖版，露出更多相邻卡片）或背景图（横版）。
    let style: LibraryPreferences.ArtworkStyle
    let size: LibraryPreferences.HeroSize

    /// 第几份副本中的第几个条目。
    private struct Slot: Hashable {
        var copy: Int
        var index: Int
    }

    private struct AdvanceKey: Hashable {
        var visible: Slot?
        var isScrolling: Bool
        var itemIDs: [String]
        var trailerPlaying: Bool
    }

    @State private var position: ScrollPosition
    @State private var visible: Slot?
    @State private var isScrolling = false
    /// 居中卡片正在播放预告片：暂停自动翻页，播完后立即翻到下一页。
    @State private var trailerPlaying = false
    @Environment(AppModel.self) private var app

    private static let interval: Duration = .seconds(8)

    init(items: [MediaItem], compact: Bool, layout: VelaLayout, style: LibraryPreferences.ArtworkStyle, size: LibraryPreferences.HeroSize) {
        self.items = items
        self.compact = compact
        self.layout = layout
        self.style = style
        self.size = size
        _position = State(initialValue: ScrollPosition(id: Slot(copy: items.count > 1 ? 1 : 0, index: 0), anchor: .center))
    }

    /// 只有一个条目时不循环。
    private var copies: Int { items.count > 1 ? 3 : 1 }
    private var middle: Int { copies / 2 }

    private var immersive: Bool { layout.isWide && style == .backdrop }

    /// 轮播高度（pt）：「大号」为基准，按 `HeroSize.scale` 缩放。
    private var height: CGFloat {
        let base: CGFloat = if immersive {
            layout == .expanded ? 600 : 500
        } else if style == .poster {
            compact ? 360 : 460
        } else {
            compact ? 260 : 380
        }
        return base * size.scale
    }

    private var slots: [Slot] {
        (0..<copies).flatMap { copy in items.indices.map { Slot(copy: copy, index: $0) } }
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = if immersive {
                proxy.size.width
            } else if style == .poster {
                min(proxy.size.width * 0.8, proxy.size.height * 2 / 3)
            } else {
                proxy.size.width * (compact ? 0.8 : 0.62)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: immersive ? 0 : 10) {
                    ForEach(slots, id: \.self) { slot in
                        NavigationLink(value: items[slot.index]) {
                            Group {
                                if immersive {
                                    ImmersiveHeroCard(item: items[slot.index], margin: layout.pageMargin)
                                } else {
                                    CarouselCard(item: items[slot.index], style: style)
                                }
                            }
                            .frame(width: cardWidth, height: proxy.size.height)
                            .overlay {
                                if slot == visible, !isScrolling, app.libraryPreferences.autoplayTrailers {
                                    InlineTrailerOverlay(item: items[slot.index]) {
                                        trailerPlaying = true
                                    } onFinish: {
                                        guard trailerPlaying else { return }
                                        trailerPlaying = false
                                        advance()
                                    }
                                    .clipShape(.rect(cornerRadius: immersive ? 0 : 28))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, (proxy.size.width - cardWidth) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .velaHideHorizontalScrollIndicators()
            .scrollPosition($position, anchor: .center)
            // 居中的卡片完全可见，两侧只露出一部分。
            .onScrollTargetVisibilityChange(idType: Slot.self, threshold: 0.95) { ids in
                if let id = ids.first { visible = id }
            }
            .onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
                if phase == .idle { recenter() }
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottomTrailing) {
            if immersive, items.count > 1 {
                PageDots(count: items.count, current: visible?.index ?? 0)
                    .padding(.trailing, layout.pageMargin)
                    .padding(.bottom, VelaTheme.Spacing.l)
            }
        }
        .task(id: AdvanceKey(visible: visible, isScrolling: isScrolling, itemIDs: items.map(\.id), trailerPlaying: trailerPlaying)) {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled, !isScrolling, !trailerPlaying else { return }
            advance()
        }
        .onChange(of: visible) { trailerPlaying = false }
        .onChange(of: items.map(\.id)) {
            visible = nil
            position.scrollTo(id: Slot(copy: middle, index: 0), anchor: .center)
        }
    }

    private func advance() {
        guard items.count > 1 else { return }
        let current = visible ?? Slot(copy: middle, index: 0)
        let next = current.index + 1 < items.count
            ? Slot(copy: current.copy, index: current.index + 1)
            : Slot(copy: min(current.copy + 1, copies - 1), index: 0)
        withAnimation(.easeInOut(duration: 0.6)) { position.scrollTo(id: next, anchor: .center) }
    }

    /// 停在首尾两份副本时跳回中间一份的同一条目（无动画，画面不变）。
    private func recenter() {
        guard let visible, visible.copy != middle, items.indices.contains(visible.index) else { return }
        let target = Slot(copy: middle, index: visible.index)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(id: target, anchor: .center) }
        self.visible = target
    }
}

/// 宽屏沉浸式头图的一页：背景图铺满，左侧与底部压暗，左下为 Logo / 标题、元数据与两行简介（与页面边距对齐）。
private struct ImmersiveHeroCard: View {
    let item: MediaItem
    let margin: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        Color.clear
            .overlay {
                RemoteArtwork(url: app.imageURL(for: item, kind: .backdrop, maxWidth: 1920), placeholderSymbol: "film")
            }
            .overlay {
                // 左侧与底部两道渐变：文字区域足够暗，右上方保留画面。
                ZStack {
                    LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5))
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.75), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .overlay(alignment: .bottomLeading) {
                info
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.leading, margin)
                    .padding(.trailing, margin + 120)
                    .padding(.bottom, VelaTheme.Spacing.xl)
            }
            .clipped()
            .contentShape(.rect)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let logo = app.client(forServerID: item.serverID)?.logoURL(for: item, maxWidth: 800) {
                CachedImage(url: logo, contentMode: .fit) { title }
                    .frame(maxWidth: 360, maxHeight: 110, alignment: .leading)
                    .accessibilityLabel(item.name)
            } else {
                title
            }
            CarouselMetadataRow(item: item)
            if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        }
        .foregroundStyle(.white)
    }

    private var title: some View {
        Text(item.name)
            .font(.largeTitle.weight(.bold))
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 4)
    }
}

/// 沉浸式头图右下角的页码点：当前页为加长胶囊。
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.4))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityHidden(true)
    }
}

private struct CarouselCard: View {
    let item: MediaItem
    let style: LibraryPreferences.ArtworkStyle
    @Environment(AppModel.self) private var app

    var body: some View {
        Color.clear
            .overlay {
                RemoteArtwork(
                    url: style == .poster
                        ? app.imageURL(for: item, kind: .primary, maxWidth: 800)
                        : app.imageURL(for: item, kind: .backdrop, maxWidth: 1280),
                    placeholderSymbol: "film"
                )
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.18), location: 0),
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.35), location: 0.75),
                        .init(color: .black.opacity(0.75), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottom) { info.padding(.horizontal, 16).padding(.bottom, 14) }
            .clipShape(.rect(cornerRadius: 28))
            .contentShape(.rect(cornerRadius: 28))
    }

    private var info: some View {
        VStack(spacing: 6) {
            if let logo = app.client(forServerID: item.serverID)?.logoURL(for: item, maxWidth: 600) {
                CachedImage(url: logo, contentMode: .fit) { title }
                    .frame(maxWidth: 240, maxHeight: 70)
                    .accessibilityLabel(item.name)
            } else {
                title
            }
            CarouselMetadataRow(item: item)
        }
        .foregroundStyle(.white)
    }

    private var title: some View {
        Text(item.name)
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 4)
    }
}

/// 「★ 7.2  2014  家庭/动画/喜剧  [TV-PG]」。
struct CarouselMetadataRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 10) {
            if let rating = item.communityRating, rating > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundStyle(.red)
                    Text(rating.formatted(.number.precision(.fractionLength(1))))
                }
                .fixedSize()
            }
            if let year = item.productionYear {
                Text(String(year)).fixedSize()
            }
            // 卡片较窄（轮播「小」号的竖版海报）时只截断类型，评分、年份与分级保持完整。
            if !item.genres.isEmpty {
                Text(item.genres.prefix(3).joined(separator: "/")).lineLimit(1).layoutPriority(-1)
            }
            if let official = item.officialRating, !official.isEmpty {
                Text(official)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
                    .fixedSize()
            }
        }
        .font(.footnote.weight(.medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

// MARK: - 顶部悬浮栏

/// 左：分类胶囊（首页 / 电影 / 剧集）；右：线路切换（多条线路时）、投屏、头像（切换服务器 / 下载 / 添加服务器）。
private struct HomeTopBar: View {
    @Binding var category: HomeModel.Category
    @Environment(AppModel.self) private var app
    @State private var isAddingServer = false

    var body: some View {
        // 顶栏的玻璃控件放进同一容器：相邻玻璃一起渲染、互相融合，而不是各自取样叠加（HIG Materials）。
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Picker("分类", selection: $category) {
                        ForEach(HomeModel.Category.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.tv.fill")
                            .foregroundStyle(VelaTheme.accent)
                        Text(category.title).font(.headline)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分类：\(category.title)")

                Spacer()

                if let server = app.servers.activeServer, server.lines.count > 1 {
                    Menu { LineMenuContent(server: server) } label: { circleIcon("bolt.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("切换线路")
                }

                #if os(iOS)
                AirPlayButton()
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                #endif

                Menu {
                    ServerMenuContent { isAddingServer = true }
                } label: {
                    CachedImage(url: app.activeClient?.userImageURL) {
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.circle)
                    .padding(2)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("服务器：\(app.servers.activeServer?.displayName ?? "")")
            }
        }
        .velaPageMargin()
        .padding(.top, 4)
        .sheet(isPresented: $isAddingServer) { AddServerView() }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// 线路切换菜单的内容（iOS 顶部栏与 Mac 工具栏共用）。
private struct LineMenuContent: View {
    let server: SavedServer
    @Environment(AppModel.self) private var app

    var body: some View {
        Picker("线路", selection: Binding(
            get: { server.activeLine.id },
            set: { app.lineRouter.switchManually(serverID: server.id, lineID: $0) }
        )) {
            ForEach(server.lines) { Text(LineRouting.displayName(of: $0)).tag($0.id) }
        }
    }
}

/// 服务器菜单的内容：切换服务器、下载、添加服务器（iOS 顶部栏与 Mac 工具栏共用）。
private struct ServerMenuContent: View {
    let addServer: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        Picker("当前服务器", selection: Binding(
            get: { app.servers.activeServer?.id },
            set: { if let id = $0 { app.servers.activate(id) } }
        )) {
            ForEach(app.servers.servers) { server in
                Label(server.displayName, systemImage: server.isPrivate ? "lock" : "server.rack")
                    .tag(Optional(server.id))
            }
        }
        Divider()
        NavigationLink(value: HomeListRoute.downloads) { Label("下载", systemImage: "arrow.down.circle") }
        Button("添加服务器…", systemImage: "plus", action: addServer)
    }
}

#if os(macOS)
/// Mac 首页工具栏：左侧分类分段控件，右侧线路与服务器菜单。
private struct HomeToolbar: ToolbarContent {
    @Binding var category: HomeModel.Category
    @Environment(AppModel.self) private var app
    @State private var isAddingServer = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("分类", selection: $category) {
                ForEach(HomeModel.Category.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let server = app.servers.activeServer, server.lines.count > 1 {
                Menu { LineMenuContent(server: server) } label: { Label("线路", systemImage: "bolt.fill") }
                    .help("切换线路")
            }
            Menu {
                ServerMenuContent { isAddingServer = true }
            } label: {
                Label(app.servers.activeServer?.displayName ?? "服务器", systemImage: "server.rack")
            }
            .help("切换服务器")
            .sheet(isPresented: $isAddingServer) { AddServerView() }
        }
    }
}
#endif

#if os(iOS)
/// 系统 AirPlay 投屏选择器。
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

extension Color {
    /// 页面背景色。
    static var homeBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension LoadState {
    init(_ result: Result<Value, any Error>) {
        switch result {
        case .success(let value): self = .loaded(value)
        case .failure(let error): self = .failed(error.localizedDescription)
        }
    }
}

/// 把抛错的异步调用转为 `Result`，便于多个分区并发加载、各自处理失败。
func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
