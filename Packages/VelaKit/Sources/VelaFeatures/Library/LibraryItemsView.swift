import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 媒体库页，与 Android 版一致：全部 / 推荐 / 类型 / 文件夹 四个分段；
/// 「全部」顶部为工具条（条目数、随机播放、海报 / 横版样式、观看状态筛选、排序——再次选择当前排序切换方向）。
struct LibraryItemsView: View {
    let library: MediaItem

    enum Tab: Hashable { case all, recommended, genres, folders }

    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var tab: Tab = .all
    @State private var sort: LibrarySort
    @State private var played: Bool?
    @State private var counts = GridCounts()
    @State private var shuffleError: String?
    @AppStorage("library.imageStyle") private var imageStyle: LibraryImageStyle = .poster

    /// - Parameter initialSort: 本次进入临时使用的排序（如首页「最近添加 →」按添加日期），不会写回该库记住的排序；
    ///   为 nil 时使用该库记住的排序。
    init(library: MediaItem, initialSort: LibrarySort? = nil, mixedContentView: LibraryPreferences.MixedContentView = .folders) {
        self.library = library
        // 「混合内容优先展示视图」：未指定类型的媒体库默认打开文件夹或全部。
        if library.collectionType == nil || library.collectionType?.isEmpty == true {
            _tab = State(initialValue: mixedContentView == .folders ? .folders : .all)
        }
        _sort = State(initialValue: initialSort ?? LibrarySort.load(libraryID: library.id, collectionType: library.collectionType))
    }

    /// 「列表中显示合集」开启时，电影库把同一合集的电影折叠为合集条目。
    private var allItemsQuery: ItemQuery {
        var query = ItemQuery(parentID: library.id, includeItemTypes: LibraryItemsView.itemTypes(for: library), recursive: true)
        if app.libraryPreferences.showCollections, library.collectionType?.lowercased() == "movies" {
            query.collapseBoxSets = true
            query.includeItemTypes += ["BoxSet"]
        }
        return query
    }

    /// 合集库没有推荐 / 类型维度。
    private var tabs: [(Tab, String)] {
        library.collectionType?.lowercased() == "boxsets"
            ? [(.all, "全部"), (.folders, "文件夹")]
            : [(.all, "全部"), (.recommended, "推荐"), (.genres, "类型"), (.folders, "文件夹")]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabPills(tabs: tabs, selection: $tab)
                .velaPageMargin()
                .padding(.bottom, VelaTheme.Spacing.s)

            switch tab {
            case .all:
                PagedItemGrid(
                    serverID: library.serverID,
                    template: allItemsQuery,
                    sort: sort,
                    played: played,
                    style: imageStyle,
                    counts: $counts
                ) {
                    // macOS 的工具条控件在窗口工具栏（第 3.5 节），条目数在窗口副标题。
                    #if os(iOS)
                    chromeBar
                    #endif
                }
            case .recommended:
                LibraryRecommendationsView(library: library)
            case .genres:
                FacetGrid(library: library, facet: .genres)
            case .folders:
                FolderContentsView(parentID: library.id, serverID: library.serverID)
            }
        }
        .navigationTitle(library.name)
        .navigationSubtitle(counts.total > 0 ? "\(counts.loaded) / \(counts.total) 项" : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar {
            if tab == .all {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("随机播放", systemImage: "shuffle") { Task { await shuffle() } }
                        .disabled(counts.total == 0)
                        .help("随机播放")
                    Button(imageStyle == .poster ? "横版样式" : "海报样式", systemImage: imageStyle == .poster ? "square.grid.2x2" : "rectangle.grid.1x2") {
                        imageStyle = imageStyle == .poster ? .landscape : .poster
                    }
                    .help(imageStyle == .poster ? "横版样式" : "海报样式")
                    filterMenu
                    sortMenu
                }
            }
        }
        #endif
        .navigationDestination(for: FacetRoute.self) { FacetItemsView(route: $0) }
        .navigationDestination(for: FolderRoute.self) { route in
            FolderContentsView(parentID: route.folder.id, serverID: route.folder.serverID)
                .navigationTitle(route.folder.name)
        }
        .alert("随机播放失败", isPresented: Binding(get: { shuffleError != nil }, set: { if !$0 { shuffleError = nil } })) {
            Button("好") {}
        } message: {
            Text(shuffleError ?? "")
        }
    }

    /// 「64 项 ⤨ ········ ▦ ⏷ ≡ 发行日期 ↓」。
    private var chromeBar: some View {
        HStack(spacing: 4) {
            Text("\(counts.total) 项")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Button("随机播放", systemImage: "shuffle") { Task { await shuffle() } }
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 36)
                .disabled(counts.total == 0)
            Spacer()
            Button(imageStyle == .poster ? "横版样式" : "海报样式", systemImage: imageStyle == .poster ? "square.grid.2x2" : "rectangle.grid.1x2") {
                imageStyle = imageStyle == .poster ? .landscape : .poster
            }
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)
            filterMenu
            sortMenu
        }
        .buttonStyle(.plain)
        .font(.body)
    }

    private var filterMenu: some View {
        Menu {
            Picker("观看状态", selection: $played) {
                Text("全部").tag(Bool?.none)
                Text("未看").tag(Bool?.some(false))
                Text("已看").tag(Bool?.some(true))
            }
        } label: {
            Image(systemName: played == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(played == nil ? Color.primary : VelaTheme.accent)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("筛选")
    }

    private var sortMenu: some View {
        // 只在用户手动改排序时记住，临时传入的 initialSort 不覆盖已保存的偏好。
        LibrarySortMenu(options: LibrarySort.fields(for: library.collectionType), sort: $sort) { $0.save(libraryID: library.id) }
    }

    /// 从本库随机挑一个可播放条目从头播放（剧集库挑单集）。
    private func shuffle() async {
        guard let client = app.client(forServerID: library.serverID) else { return }
        let types: [String] = switch library.collectionType?.lowercased() {
        case "movies": ["Movie"]
        case "tvshows": ["Episode"]
        default: ["Movie", "Episode", "Video"]
        }
        do {
            let page = try await client.items(ItemQuery(parentID: library.id, includeItemTypes: types, recursive: true, sortBy: .random, limit: 1))
            guard let item = page.items.first else {
                shuffleError = "这个媒体库里没有可播放的条目。"
                return
            }
            playMedia(.item(item, options: .init(startFromBeginning: true)))
        } catch {
            shuffleError = error.localizedDescription
        }
    }

    /// 按库类型取条目：合集库只列合集，其余库列影片 / 剧集 / 视频（不把合集混进电影库）。
    static func itemTypes(for library: MediaItem) -> [String] {
        switch library.collectionType?.lowercased() {
        case "boxsets": ["BoxSet"]
        case "movies": ["Movie"]
        case "tvshows": ["Series"]
        default: ["Movie", "Series", "Video", "BoxSet"]
        }
    }
}

/// 网格卡片样式：竖版海报或横版剧照。全局记住。
enum LibraryImageStyle: String {
    case poster, landscape
}

/// 胶囊分段：选中项为 Liquid Glass 胶囊，其余为次要文字（与 Android 版媒体库分段一致）。
struct TabPills<Value: Hashable>: View {
    let tabs: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.0) { value, title in
                    Button {
                        withAnimation(.snappy) { selection = value }
                    } label: {
                        Text(title)
                            .font(.subheadline.weight(selection == value ? .semibold : .regular))
                            .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(selection == value ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - 排序

/// 媒体库排序：字段 + 方向，按库分别记住。
struct LibrarySort: Hashable {
    var field: ItemQuery.SortField
    var descending: Bool

    struct Option {
        var field: ItemQuery.SortField
        var title: String
    }

    static func fields(for collectionType: String?) -> [Option] {
        var options: [Option] = [
            .init(field: .name, title: "名称"),
            .init(field: .dateCreated, title: "添加日期"),
            .init(field: .premiereDate, title: "发行日期"),
            .init(field: .productionYear, title: "年份"),
            .init(field: .communityRating, title: "IMDb 评分"),
            .init(field: .criticRating, title: "影评人评分"),
            .init(field: .datePlayed, title: "播放日期")
        ]
        if collectionType?.lowercased() == "tvshows" {
            options.append(.init(field: .dateLastContentAdded, title: "最后一集添加日期"))
        }
        options += [
            .init(field: .playCount, title: "播放次数"),
            .init(field: .random, title: "随机"),
            .init(field: .officialRating, title: "分级")
        ]
        return options
    }

    private static func key(_ libraryID: String) -> String { "library.sort.\(libraryID)" }

    static func load(libraryID: String, collectionType: String?) -> LibrarySort {
        if let raw = UserDefaults.standard.string(forKey: key(libraryID)) {
            let parts = raw.split(separator: ":")
            if parts.count == 2, let field = ItemQuery.SortField(rawValue: String(parts[0])) {
                return LibrarySort(field: field, descending: parts[1] == "desc")
            }
        }
        return LibrarySort(field: .dateCreated, descending: true)
    }

    func save(libraryID: String) {
        UserDefaults.standard.set("\(field.rawValue):\(descending ? "desc" : "asc")", forKey: Self.key(libraryID))
    }
}

/// 排序菜单，标签为「≡ 发行日期 ↓」；再次选择当前字段切换升 / 降序。
struct LibrarySortMenu: View {
    let options: [LibrarySort.Option]
    @Binding var sort: LibrarySort
    /// 用户改动排序后调用（媒体库据此按库记住排序）。
    var onChange: (LibrarySort) -> Void = { _ in }

    var body: some View {
        let current = options.first { $0.field == sort.field }?.title ?? "排序"
        Menu {
            ForEach(options, id: \.field) { option in
                Button {
                    if sort.field == option.field {
                        sort.descending.toggle()
                    } else {
                        sort = LibrarySort(field: option.field, descending: option.field != .name)
                    }
                    onChange(sort)
                } label: {
                    if sort.field == option.field {
                        Label(option.title, systemImage: sort.descending ? "arrow.down" : "arrow.up")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                Text(sort.field == .random ? current : "\(current) \(sort.descending ? "↓" : "↑")")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 4)
            .frame(height: 36)
        }
        .accessibilityLabel("排序：\(current)")
    }
}

// MARK: - 条目网格

/// 分页网格已加载 / 总条目数，供标题副标题「60 / 64 项」与工具条使用。
struct GridCounts: Equatable {
    var loaded = 0
    var total = 0
}

/// 分页网格：同一部电影的多个文件合并为一张卡片；接近末尾时提前加载下一页。
/// `header` 放在网格之上、随内容滚动（媒体库「全部」的工具条）。
struct PagedItemGrid<Header: View>: View {
    let serverID: String
    let template: ItemQuery
    let sort: LibrarySort
    let played: Bool?
    var style: LibraryImageStyle = .poster
    var counts: Binding<GridCounts>?
    @ViewBuilder var header: () -> Header

    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var items: [MediaItem] = []
    @State private var total = 0
    /// 已取到的原始条目数（合并前），分页偏移与「是否还有下一页」都以它为准。
    @State private var fetchedCount = 0
    /// 已取到的原始条目 id；随机排序每页都由服务器重新打乱，跨页会重复，据此去重（重复 id 会让网格错乱）。
    @State private var fetchedIDs: Set<String> = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedOnce = false
    /// 当前内容对应的查询；从详情页返回时视图重新出现、`.task` 会再次执行，查询未变且上次成功时不重新加载，
    /// 保留已加载的条目与滚动位置（随机排序也不会被重新打乱）。
    @State private var loadedKey: QueryKey?

    private static var pageSize: Int { 60 }
    /// 距离末尾还剩多少项时开始加载下一页，滚动到底前数据已就绪。
    private static var prefetchDistance: Int { 18 }

    private struct QueryKey: Hashable {
        var template: ItemQuery
        var sort: LibrarySort
        var played: Bool?
    }

    private var queryKey: QueryKey { QueryKey(template: template, sort: sort, played: played) }

    private var cardWidth: CGFloat {
        // 宽屏横卡随分档放大（260 / 320 / 360 减去网格间距余量），与首页横卡观感一致。
        style == .poster ? layout.posterWidth : (isCompact ? HomeView.landscapeWidth(compact: true) : layout.landscapeCardWidth) - 20
    }

    var body: some View {
        ScrollView {
            header()
                .velaPageMargin()
            // iPhone 竖屏要放下三列海报（与 Android 版一致），列间距与边距比其他页面略紧。
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardWidth), spacing: isCompact ? 10 : VelaTheme.Spacing.m, alignment: .top)],
                spacing: VelaTheme.Spacing.l
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: item) { card(item) }
                        .buttonStyle(.plain)
                        .itemContextMenu(item)
                        .onAppear {
                            if index >= items.count - Self.prefetchDistance { Task { await loadMore() } }
                        }
                }
            }
            // 宽屏与页头同用页面边距左对齐；iPhone 保持较紧的边距以放下三列海报。
            .padding(.horizontal, isCompact ? VelaTheme.Spacing.m : layout.pageMargin)
            .padding(.vertical, VelaTheme.Spacing.s)

            if isLoading { ProgressView().padding() }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding()
            }
            if loadedOnce, !isLoading, error == nil, items.isEmpty {
                ContentUnavailableView(played == nil ? "没有内容" : (played == true ? "没有已看的条目" : "没有未看的条目"),
                                       systemImage: "square.stack")
            }
        }
        .refreshable { await reload() }
        .task(id: queryKey) {
            guard loadedKey != queryKey || error != nil else { return }
            await reload()
        }
        .onChange(of: GridCounts(loaded: fetchedCount, total: total)) { _, value in counts?.wrappedValue = value }
    }

    @ViewBuilder
    private func card(_ item: MediaItem) -> some View {
        switch style {
        case .poster:
            PosterCard(
                title: item.name,
                subtitle: item.productionYear.map(String.init),
                imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                progress: item.playedFraction,
                width: cardWidth,
                badges: PosterBadges(item)
            )
        case .landscape:
            // 单集的标题多是「第 N 集」，改为剧名 + 「S01 E05 - 集名」（非单集时副标题仍是年份）。
            LandscapeCard(
                title: item.kind == .episode ? item.seriesName ?? item.name : item.name,
                subtitle: HomeView.episodeSubtitle(item),
                imageURL: app.imageURL(for: item, kind: .thumb, maxWidth: 640)
                    ?? app.imageURL(for: item, kind: .backdrop, maxWidth: 640)
                    ?? app.imageURL(for: item, kind: .primary, maxWidth: 640),
                progress: item.playedFraction,
                width: cardWidth
            )
        }
    }

    private func reload() async {
        items = []
        total = 0
        fetchedCount = 0
        fetchedIDs = []
        error = nil
        loadedKey = queryKey
        await loadMore()
        loadedOnce = true
    }

    private func loadMore() async {
        guard !isLoading, fetchedCount == 0 || fetchedCount < total, let client = app.client(forServerID: serverID) else { return }
        isLoading = true
        defer { isLoading = false }
        var query = template
        query.sortBy = sort.field
        query.sortDescending = sort.descending
        query.startIndex = fetchedCount
        query.limit = Self.pageSize
        query.isPlayed = played
        do {
            let page = try await client.items(query)
            // 偏移仍按服务器返回的条数推进；随机排序下跨页重复的条目丢弃（代价是少数条目可能取不到）。
            let fresh = page.items.filter { fetchedIDs.insert($0.id).inserted }
            // 同一部电影的多个文件合并为一张卡片（可能跨页，因此对全部条目重新合并）。
            items = MediaItemMerger.merge(items + fresh)
            fetchedCount += page.items.count
            total = page.total
            error = nil
            if style == .poster {
                ImagePipeline.shared.prefetch(page.items.compactMap { app.imageURL(for: $0, kind: .primary, maxWidth: 400) })
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension PagedItemGrid where Header == EmptyView {
    init(serverID: String, template: ItemQuery, sort: LibrarySort, played: Bool?) {
        self.init(serverID: serverID, template: template, sort: sort, played: played) { EmptyView() }
    }
}

// MARK: - 风格 / 工作室

struct FacetRoute: Hashable {
    var library: MediaItem
    var facet: MediaServerClient.Facet
    var value: MediaItem
}

/// 风格 / 工作室网格：有图片时显示图片，没有时用名称 + 渐变色块。
private struct FacetGrid: View {
    let library: MediaItem
    let facet: MediaServerClient.Facet
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var facets: LoadState<[MediaItem]> = .idle

    var body: some View {
        ScrollView {
            switch facets {
            case .loaded(let list) where list.isEmpty:
                ContentUnavailableView(facet == .genres ? "没有风格" : "没有工作室", systemImage: "tag")
            case .loaded(let list):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 150 : 200), spacing: VelaTheme.Spacing.m)], spacing: VelaTheme.Spacing.m) {
                    ForEach(list) { value in
                        NavigationLink(value: FacetRoute(library: library, facet: facet, value: value)) {
                            FacetTile(value: value, imageURL: app.imageURL(for: value, kind: .primary, maxWidth: 400))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, VelaTheme.Spacing.l)
                .velaPageMargin()
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().padding(.top, 40)
            }
        }
        // 从下级页面返回时已有内容，不重新请求。
        .task { if facets.value == nil { await load() } }
    }

    private func load() async {
        guard let client = app.client(forServerID: library.serverID) else { return }
        if facets.value == nil { facets = .loading }
        facets = LoadState(await capture { try await client.facets(facet, parentID: library.id) })
    }
}

private struct FacetTile: View {
    let value: MediaItem
    let imageURL: URL?

    var body: some View {
        // 名称决定渐变色：按字符码累加（`hashValue` 每次启动都会变），同一风格颜色固定。
        let hue = Double(value.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        CachedImage(url: imageURL) {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue, saturation: 0.7, brightness: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .overlay {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottomLeading) {
            Text(value.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(VelaTheme.Spacing.s)
        }
        .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
    }
}

/// 某个风格 / 工作室下的条目。
private struct FacetItemsView: View {
    let route: FacetRoute
    @State private var sort = LibrarySort(field: .premiereDate, descending: true)

    var body: some View {
        var template = ItemQuery(parentID: route.library.id, includeItemTypes: LibraryItemsView.itemTypes(for: route.library), recursive: true)
        if route.facet == .genres { template.genreIDs = [route.value.id] } else { template.studioIDs = [route.value.id] }
        return PagedItemGrid(serverID: route.library.serverID, template: template, sort: sort, played: nil)
            .navigationTitle(route.value.name)
    }
}

// MARK: - 文件夹

struct FolderRoute: Hashable {
    var folder: MediaItem
}

/// 按服务器上的目录结构浏览：文件夹可继续进入，条目进入详情。
private struct FolderContentsView: View {
    let parentID: String
    let serverID: String
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var content: LoadState<[MediaItem]> = .idle

    private static let limit = 500

    var body: some View {
        ScrollView {
            switch content {
            case .loaded(let list) where list.isEmpty:
                ContentUnavailableView("空文件夹", systemImage: "folder")
            case .loaded(let list):
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: layout.posterWidth), spacing: VelaTheme.Spacing.m, alignment: .top)],
                    spacing: VelaTheme.Spacing.l
                ) {
                    ForEach(list) { item in
                        if item.kind == .folder || item.kind == .collectionFolder {
                            NavigationLink(value: FolderRoute(folder: item)) { folderCard(item) }.buttonStyle(.plain)
                        } else {
                            NavigationLink(value: item) {
                                PosterCard(
                                    title: item.name,
                                    subtitle: item.productionYear.map(String.init),
                                    imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                                    progress: item.playedFraction,
                                    width: layout.posterWidth,
                                    badges: PosterBadges(item)
                                )
                            }
                            .buttonStyle(.plain)
                            .itemContextMenu(item)
                        }
                    }
                }
                .padding(VelaTheme.Spacing.l)
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().padding(.top, 40)
            }
        }
        // 从详情 / 子文件夹返回时已有内容，不重新请求，保持滚动位置；加载失败时重新出现会重试。
        .task(id: parentID) { if content.value == nil { await load() } }
    }

    private func folderCard(_ item: MediaItem) -> some View {
        let width = layout.posterWidth
        return VStack(alignment: .leading, spacing: VelaTheme.Spacing.xs) {
            CachedImage(url: app.imageURL(for: item, kind: .primary, maxWidth: 400)) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.tint)
                }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
            Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
            if let count = item.childCount {
                Text("\(count) 项").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func load() async {
        guard let client = app.client(forServerID: serverID) else { return }
        if content.value == nil { content = .loading }
        content = LoadState(await capture {
            // 文件夹排在前面，其余按名称。
            try await client.items(ItemQuery(parentID: parentID, recursive: false, sortBy: .name, limit: Self.limit)).items
                .sorted { ($0.kind == .folder ? 0 : 1) < ($1.kind == .folder ? 0 : 1) }
        })
    }
}

// MARK: - 推荐

/// 媒体库「推荐」分段：本库的继续观看、接下来（剧集库）、最近添加、高分、随机发现，各行独立加载与失败。
private struct LibraryRecommendationsView: View {
    let library: MediaItem

    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var rows: [Row] = []
    @State private var hasLoaded = false

    private static let rowLimit = 16

    struct Row: Identifiable {
        var title: String
        var items: [MediaItem]
        var landscape: Bool
        var id: String { title }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                ForEach(rows) { row in
                    MediaShelf(row.title, items: row.items) { item in
                        NavigationLink(value: item) { card(item, landscape: row.landscape) }.buttonStyle(.plain).itemContextMenu(item)
                    }
                }
                if hasLoaded, rows.isEmpty {
                    ContentUnavailableView("暂无推荐", systemImage: "sparkles")
                }
            }
            .padding(.vertical, VelaTheme.Spacing.s)
        }
        .overlay { if !hasLoaded { ProgressView() } }
        .refreshable { await load() }
        .task { if !hasLoaded { await load() } }
    }

    @ViewBuilder
    private func card(_ item: MediaItem, landscape: Bool) -> some View {
        if landscape {
            LandscapeCard(
                title: item.seriesName ?? item.name,
                subtitle: HomeView.episodeSubtitle(item),
                imageURL: app.imageURL(for: item, kind: .thumb, maxWidth: 640)
                    ?? app.imageURL(for: item, kind: .backdrop, maxWidth: 640)
                    ?? app.imageURL(for: item, kind: .primary, maxWidth: 640),
                progress: item.playedFraction,
                width: HomeView.landscapeWidth(compact: isCompact),
                caption: HomeView.remainingCaption(item)
            )
        } else {
            PosterCard(
                title: item.name,
                subtitle: item.productionYear.map(String.init),
                imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 400),
                width: layout.posterWidth,
                badges: PosterBadges(item)
            )
        }
    }

    private func load() async {
        guard let client = app.client(forServerID: library.serverID) else {
            hasLoaded = true
            return
        }
        let parentID = library.id
        let types = LibraryItemsView.itemTypes(for: library)
        let limit = Self.rowLimit
        let isShows = library.collectionType?.lowercased() == "tvshows"
        async let resume = capture { try await client.resume(limit: limit, parentID: parentID).items }
        async let nextUp = capture { isShows ? try await client.nextUpPage(limit: limit, parentID: parentID).items : [] }
        async let latest = capture { try await client.latestItems(parentID: parentID, limit: limit) }
        async let topRated = capture {
            try await client.items(ItemQuery(parentID: parentID, includeItemTypes: types, recursive: true,
                                             sortBy: .communityRating, sortDescending: true, limit: limit)).items
        }
        async let random = capture {
            try await client.items(ItemQuery(parentID: parentID, includeItemTypes: types, recursive: true,
                                             sortBy: .random, limit: limit)).items
        }
        // 单行失败只少一行；全部为空时显示「暂无推荐」。
        let candidates: [(String, Result<[MediaItem], any Error>, Bool)] = [
            ("继续观看", await resume, true),
            ("接下来", await nextUp, true),
            ("最近添加", await latest, false),
            ("评分最高", await topRated, false),
            ("随机发现", await random, false)
        ]
        rows = candidates.compactMap { title, result, landscape in
            guard let items = try? result.get(), !items.isEmpty else { return nil }
            return Row(title: title, items: landscape ? items : MediaItemMerger.merge(items), landscape: landscape)
        }
        hasLoaded = true
    }
}
