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
    @State private var model = HomeModel()
    @SceneStorage("home.category") private var category: HomeModel.Category = .home

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                    // 与 Android 版一致：顶部栏属于轮播区，随内容滚走，不遮挡下方分区。
                    HomeTopBar(category: $category)
                    let featured = featuredItems
                    if !featured.isEmpty {
                        HomeCarousel(items: featured, compact: isCompact)
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
            #endif
            .navigationTitle(app.servers.activeServer?.displayName ?? "首页")
            .navigationDestination(for: HomeListRoute.self) { route in
                if route == .downloads { DownloadsView() } else { HomeListView(route: route) }
            }
            .navigationDestination(for: LibraryRoute.self) { LibraryItemsView(library: $0.library) }
            .navigationDestination(for: GenreRoute.self) { GenreItemsView(route: $0) }
            .detailDestinations()
            .refreshable { await load() }
            .task(id: app.servers.activeServer?.baseURL) { await load() }
            .task(id: TaskKey(category: category, server: app.servers.activeServer?.baseURL)) {
                guard let client = app.activeClient else { return }
                await model.loadGenres(category, client: client)
            }
        }
    }

    private struct TaskKey: Hashable {
        var category: HomeModel.Category
        var server: URL?
    }

    /// 分类下轮播只显示对应类型；没有对应类型时退回全部，避免轮播消失。
    private var featuredItems: [MediaItem] {
        let kind: MediaItem.Kind? = switch category {
        case .home: nil
        case .movies: .movie
        case .tvShows: .series
        }
        guard let kind else { return model.featured }
        let filtered = model.featured.filter { $0.kind == kind }
        return filtered.isEmpty ? model.featured : filtered
    }

    // MARK: - 首页分类

    @ViewBuilder
    private var homeContent: some View {
        if !model.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }

        if !model.libraries.isEmpty {
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

        if !model.resume.isEmpty {
            MediaShelf("继续观看", items: model.resume) { item in
                NavigationLink(value: item) { resumeCard(item) }.buttonStyle(.plain)
            } accessory: {
                NavigationLink(value: HomeListRoute.resume) { ShelfCountLabel(count: model.resumeTotal) }
                    .buttonStyle(.plain)
            }
        }

        if !model.nextUp.isEmpty {
            MediaShelf("接下来", items: model.nextUp) { item in
                NavigationLink(value: item) { resumeCard(item) }.buttonStyle(.plain)
            } accessory: {
                NavigationLink(value: HomeListRoute.nextUp) { ShelfCountLabel(count: model.nextUpTotal) }
                    .buttonStyle(.plain)
            }
        }

        ForEach(model.shelves) { shelf in
            MediaShelf("最近添加-\(shelf.library.name)", items: shelf.items) { item in
                NavigationLink(value: item) { posterCard(item) }.buttonStyle(.plain)
            } accessory: {
                NavigationLink(value: LibraryRoute(library: shelf.library)) { ShelfViewAllArrow() }
                    .buttonStyle(.plain)
            }
        }

        failureLabels

        if model.isEmpty {
            ContentUnavailableView("暂无内容", systemImage: "film.stack", description: Text("服务器上还没有可展示的内容。"))
        }

        if let counts = model.counts, counts.movieCount + counts.seriesCount + counts.episodeCount > 0 {
            LibraryStatistics(counts: counts)
        }
    }

    @ViewBuilder
    private var failureLabels: some View {
        ForEach(model.failures.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
            Label("\(name)加载失败：\(message)", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, VelaTheme.Spacing.l)
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
                MediaShelf(shelf.genre.name, items: shelf.items) { item in
                    NavigationLink(value: item) { posterCard(item) }.buttonStyle(.plain)
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
                .padding(.horizontal, VelaTheme.Spacing.l)
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
            width: VelaTheme.posterWidth(compact: isCompact),
            badges: PosterBadges(item)
        )
    }

    /// 继续观看 / 接下来卡片：优先剧集的横版图（Thumb → Backdrop），单集退回单集截图；右上角显示剩余时长。
    private func resumeCard(_ item: MediaItem) -> some View {
        let image = app.imageURL(for: item, kind: .thumb, maxWidth: 640)
            ?? app.imageURL(for: item, kind: .backdrop, maxWidth: 640)
            ?? app.imageURL(for: item, kind: .primary, maxWidth: 640)
        return LandscapeCard(
            title: item.seriesName ?? item.name,
            subtitle: Self.episodeSubtitle(item),
            imageURL: image,
            progress: item.playedFraction,
            width: Self.landscapeWidth(compact: isCompact),
            caption: Self.remainingCaption(item)
        )
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
    /// 剧集显示未看集数，电影显示已看勾（与 Android 版一致，海报上不叠评分）。
    init(_ item: MediaItem) {
        self.init(
            unplayedCount: item.kind == .series ? item.unplayedItemCount : nil,
            isPlayed: item.kind != .series && item.isPlayed,
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

/// 卡片式轮播（Android 版「紧凑」样式）：当前卡片占 80% 宽、两侧露出相邻卡片，8 秒自动翻页，到末尾回到第一张。
/// 不用 `TabView(.page)`：macOS 不支持，且无法露出相邻卡片。
private struct HomeCarousel: View {
    let items: [MediaItem]
    let compact: Bool
    @State private var current: String?

    private static let interval: Duration = .seconds(8)

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = proxy.size.width * (compact ? 0.8 : 0.62)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            CarouselCard(item: item)
                                .frame(width: cardWidth, height: proxy.size.height)
                        }
                        .buttonStyle(.plain)
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
        .frame(height: compact ? 260 : 380)
        .task(id: current) {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled, items.count > 1 else { return }
            let index = items.firstIndex { $0.id == current } ?? 0
            withAnimation(.easeInOut(duration: 0.6)) { current = items[(index + 1) % items.count].id }
        }
        .onAppear { if current == nil { current = items.first?.id } }
    }
}

private struct CarouselCard: View {
    let item: MediaItem
    @Environment(AppModel.self) private var app

    var body: some View {
        Color.clear
            .overlay {
                RemoteArtwork(url: app.imageURL(for: item, kind: .backdrop, maxWidth: 1280), placeholderSymbol: "film")
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
            }
            if let year = item.productionYear {
                Text(String(year))
            }
            if !item.genres.isEmpty {
                Text(item.genres.prefix(3).joined(separator: "/")).lineLimit(1)
            }
            if let official = item.officialRating, !official.isEmpty {
                Text(official)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
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
                Menu {
                    Picker("线路", selection: Binding(
                        get: { server.activeLine.id },
                        set: { app.lineRouter.switchManually(serverID: server.id, lineID: $0) }
                    )) {
                        ForEach(server.lines) { Text(LineRouting.displayName(of: $0)).tag($0.id) }
                    }
                } label: {
                    circleIcon("bolt.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换线路")
            }

            #if os(iOS)
            AirPlayButton()
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
            #endif

            Menu {
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
                Button("添加服务器…", systemImage: "plus") { isAddingServer = true }
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
        .padding(.horizontal, VelaTheme.Spacing.l)
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

// MARK: - 统计

private struct LibraryStatistics: View {
    let counts: MediaServerClient.ItemCounts

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            tile(counts.movieCount, "电影")
            tile(counts.seriesCount, "节目")
            tile(counts.episodeCount, "集数")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VelaTheme.Spacing.l)
    }

    private func tile(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(LinearGradient(colors: [VelaTheme.accentSecondary, .pink], startPoint: .leading, endPoint: .trailing))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 92)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

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
