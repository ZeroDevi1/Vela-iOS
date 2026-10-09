import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// 「发现」标签页；内容见 `DiscoverPage`。
struct DiscoverView: View {
    var body: some View {
        HistoryNavigationStack { DiscoverPage() }
    }
}

/// 发现：TMDB 目录流 + 跨服务器继续观看。目录条目不是库条目，进入详情后按 TMDB / IMDb id 精确匹配各服务器资源。
struct DiscoverPage: View {
    @Environment(AppModel.self) private var app
    @State private var model = DiscoverModel()
    @State private var category: CatalogCategory = .recommended
    @State private var isEditingCredential = false

    var body: some View {
        Group {
            if app.catalog.isConfigured {
                content
            } else {
                ContentUnavailableView {
                    Label("未配置 TMDB", systemImage: "safari")
                } description: {
                    Text("发现页的榜单与目录来自 TMDB，需要先填写 TMDB API Key 或 Read Access Token。")
                } actions: {
                    Button("填写 TMDB 凭据") { isEditingCredential = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("发现")
        .navigationDestination(for: CatalogTitle.self) { CatalogDetailView(title: $0) }
        .navigationDestination(for: CatalogShelf.self) { CatalogBrowseView(shelf: $0) }
        .detailDestinations()
        .sheet(isPresented: $isEditingCredential) {
            NavigationStack { TMDBCredentialForm() }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.xl) {
                Picker("分类", selection: $category) {
                    ForEach(CatalogCategory.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .velaPageMargin()

                if category == .recommended, !model.resume.isEmpty {
                    FederatedResumeShelf(matches: model.resume)
                }

                ForEach(category.shelves) { shelf in
                    CatalogShelfView(shelf: shelf, state: model.shelves[shelf] ?? .loading)
                }
            }
            .padding(.vertical, VelaTheme.Spacing.l)
        }
        .refreshable { await load(force: true) }
        .task(id: category) { await load(force: false) }
        .task(id: app.servers.servers.map(\.id)) {
            model.resume = await CatalogService.federatedResume(in: app.searchableSources)
        }
    }

    private func load(force: Bool) async {
        guard let client = app.catalog.client else { return }
        await model.load(category: category, client: client, force: force)
    }
}

@MainActor
@Observable
final class DiscoverModel {
    var shelves: [CatalogShelf: LoadState<[CatalogTitle]>] = [:]
    var resume: [CatalogService.Match] = []

    /// 已加载过的分区不重复请求（切换分类时），下拉刷新时强制重新加载。
    func load(category: CatalogCategory, client: TMDBClient, force: Bool) async {
        let pending = category.shelves.filter { force || shelves[$0]?.value == nil }
        await withTaskGroup(of: (CatalogShelf, LoadState<[CatalogTitle]>).self) { group in
            for shelf in pending {
                group.addTask {
                    let result = await capture { try await client.page(CatalogRequest.make(shelf: shelf), mediaType: shelf.mediaType).results }
                    return (shelf, LoadState(result))
                }
            }
            for await (shelf, state) in group { shelves[shelf] = state }
        }
    }
}

// MARK: - 分区

private struct CatalogShelfView: View {
    let shelf: CatalogShelf
    let state: LoadState<[CatalogTitle]>
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout

    var body: some View {
        switch state {
        case .loaded(let titles) where !titles.isEmpty:
            MediaShelf(shelf.title, items: titles) { title in
                NavigationLink(value: title) { CatalogPosterCard(title: title) }
                    .buttonStyle(.plain)
            } accessory: {
                NavigationLink(value: shelf) {
                    HStack(spacing: 2) {
                        Text("全部")
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        case .failed(let message):
            Label("\(shelf.title)加载失败：\(message)", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .velaPageMargin()
        case .loaded:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text(shelf.title).font(.title3.weight(.semibold))
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            .velaPageMargin()
        }
    }
}

struct CatalogPosterCard: View {
    let title: CatalogTitle
    var width: CGFloat?
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout

    var body: some View {
        PosterCard(
            title: title.title,
            subtitle: title.year.map(String.init),
            imageURL: CatalogImage.url(title.posterPath, size: .poster),
            width: width ?? layout.posterWidth,
            badges: PosterBadges(rating: title.voteAverage)
        )
    }
}

/// 所有非私密服务器的继续观看，按最近播放时间合并；卡片注明来自哪台服务器。
private struct FederatedResumeShelf: View {
    let matches: [CatalogService.Match]
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout

    var body: some View {
        MediaShelf("跨服务器继续观看", items: matches) { match in
            NavigationLink(value: match.item) {
                let item = match.item
                LandscapeCard(
                    title: item.seriesName ?? item.name,
                    subtitle: [match.serverName, HomeView.episodeSubtitle(item)].compactMap { $0 }.joined(separator: " · "),
                    imageURL: item.kind == .episode
                        ? app.imageURL(for: item, kind: .primary, maxWidth: 640)
                        : (app.imageURL(for: item, kind: .backdrop, maxWidth: 640) ?? app.imageURL(for: item, kind: .primary, maxWidth: 640)),
                    progress: item.playedFraction,
                    width: layout.landscapeCardWidth,
                    caption: HomeView.remainingCaption(item)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 查看全部

/// 分区的完整列表：分页加载；可筛选的分区提供类型 / 年份 / 排序。
struct CatalogBrowseView: View {
    let shelf: CatalogShelf
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.velaLayout) private var layout
    @State private var titles: [CatalogTitle] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var error: String?
    @State private var filter = CatalogFilter()
    @State private var genres: [TMDBClient.Genre] = []

    private static let years: [Int] = {
        let current = Calendar.current.component(.year, from: .now)
        return Array((1950...current + 1).reversed())
    }()

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: layout.posterWidth), spacing: VelaTheme.Spacing.m, alignment: .top)],
                spacing: VelaTheme.Spacing.l
            ) {
                ForEach(titles) { title in
                    NavigationLink(value: title) { CatalogPosterCard(title: title) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if title.id == titles.last?.id { Task { await loadMore() } }
                        }
                }
            }
            .padding(VelaTheme.Spacing.l)

            if isLoading { ProgressView().padding() }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding()
            }
            if !isLoading, error == nil, titles.isEmpty, page > 0 {
                ContentUnavailableView("没有符合条件的作品", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .navigationTitle(shelf.title)
        .toolbar {
            if shelf.isFilterable, shelf.mediaType != nil {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        .task(id: filter) { await reload() }
        .task {
            guard shelf.isFilterable, let type = shelf.mediaType, let client = app.catalog.client else { return }
            genres = (try? await client.genres(type)) ?? []
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("排序", selection: $filter.sort) {
                Text("默认").tag(CatalogFilter.Sort?.none)
                ForEach(CatalogFilter.Sort.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Picker("类型", selection: $filter.genreID) {
                Text("全部类型").tag(Int?.none)
                ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            Picker("年份", selection: $filter.year) {
                Text("全部年份").tag(Int?.none)
                ForEach(Self.years, id: \.self) { Text(String($0)).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            if !filter.isEmpty {
                Button("清除筛选", systemImage: "xmark.circle", role: .destructive) { filter = CatalogFilter() }
            }
        } label: {
            Label("筛选", systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private func reload() async {
        titles = []
        page = 0
        totalPages = 1
        error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, page < totalPages, let client = app.catalog.client else { return }
        isLoading = true
        defer { isLoading = false }
        let request = CatalogRequest.make(shelf: shelf, filter: filter, page: page + 1)
        do {
            let result = try await client.page(request, mediaType: shelf.mediaType)
            // 榜单翻页时 TMDB 偶尔返回重复条目，按 id 去重。
            let known = Set(titles.map(\.id))
            titles += result.results.filter { !known.contains($0.id) }
            page = result.page
            totalPages = result.totalPages
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

