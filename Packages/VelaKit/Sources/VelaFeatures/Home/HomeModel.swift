import Foundation
import Observation
import VelaCore
import VelaNetwork

/// 首页数据：轮播、继续观看、接下来播放、媒体库、各库最新、全库统计；「电影」「剧集」分类下按风格分区。
///
/// 各分区并发加载、各自失败：单个分区失败只记录到 `failures`，不影响其他分区，也不把失败当成「没有内容」。
@MainActor
@Observable
final class HomeModel {
    struct LibraryShelf: Identifiable {
        var library: MediaItem
        var items: [MediaItem]
        var total: Int
        var id: String { library.id }
    }

    /// 首页左上角的分类（与 Android 版 `HomeCategory` 一致）。
    enum Category: String, CaseIterable, Identifiable {
        case home, movies, tvShows

        var id: Self { self }

        var title: String {
            switch self {
            case .home: "首页"
            case .movies: "电影"
            case .tvShows: "剧集"
            }
        }

        /// 分类对应的条目类型；首页为 nil（不限制）。
        var itemType: String? {
            switch self {
            case .home: nil
            case .movies: "Movie"
            case .tvShows: "Series"
            }
        }
    }

    struct GenreShelf: Identifiable {
        var genre: MediaItem
        var items: [MediaItem]
        var id: String { genre.id }
    }

    /// 分类 → 风格分区；切换到该分类时才加载，换服务器时清空。
    private(set) var genreShelves: [Category: LoadState<[GenreShelf]>] = [:]
    /// 每个分类最多显示的风格分区数（按条目数从多到少）。
    private static let genreShelfLimit = 10

    private(set) var featured: [MediaItem] = []
    private(set) var resume: [MediaItem] = []
    private(set) var resumeTotal = 0
    private(set) var nextUp: [MediaItem] = []
    private(set) var nextUpTotal = 0
    private(set) var libraries: [MediaItem] = []
    private(set) var shelves: [LibraryShelf] = []
    private(set) var counts: MediaServerClient.ItemCounts?
    /// 分区名 → 失败原因。
    private(set) var failures: [String: String] = [:]
    private(set) var hasLoaded = false

    /// 每个分区的条目数。
    private static let shelfLimit = 16
    /// 轮播图数量。
    private static let featuredLimit = 8

    var isEmpty: Bool {
        hasLoaded && failures.isEmpty && featured.isEmpty && resume.isEmpty && nextUp.isEmpty && shelves.allSatisfy(\.items.isEmpty)
    }

    func load(client: MediaServerClient) async {
        genreShelves = [:]
        async let featuredTask = capture {
            try await client.items(ItemQuery(
                includeItemTypes: ["Movie", "Series"],
                recursive: true,
                sortBy: .random,
                limit: Self.featuredLimit,
                imageTypes: ["Backdrop"]
            )).items
        }
        async let resumeTask = capture { try await client.resume(limit: Self.shelfLimit) }
        async let nextUpTask = capture { try await client.nextUpPage(limit: Self.shelfLimit) }
        async let librariesTask = capture { try await client.userViews() }
        async let countsTask = capture { try await client.itemCounts() }

        var failures: [String: String] = [:]
        switch await featuredTask {
        case .success(let items): featured = items.filter { !$0.backdropImageTags.isEmpty }
        case .failure: featured = [] // 轮播只是装饰，失败时不提示。
        }
        switch await resumeTask {
        case .success(let page): (resume, resumeTotal) = page
        case .failure(let error): failures["继续观看"] = error.localizedDescription
        }
        switch await nextUpTask {
        case .success(let page): (nextUp, nextUpTotal) = page
        case .failure(let error): failures["接下来播放"] = error.localizedDescription
        }
        if case .success(let value) = await countsTask { counts = value }

        switch await librariesTask {
        case .success(let views):
            libraries = views.filter { Self.shelfQuery(for: $0) != nil }
            shelves = await loadShelves(libraries: libraries, client: client, failures: &failures)
        case .failure(let error):
            failures["媒体库"] = error.localizedDescription
        }
        self.failures = failures
        hasLoaded = true
    }

    private func loadShelves(libraries: [MediaItem], client: MediaServerClient, failures: inout [String: String]) async -> [LibraryShelf] {
        let results = await withTaskGroup(of: (Int, Result<(items: [MediaItem], total: Int), any Error>).self) { group in
            for (index, library) in libraries.enumerated() {
                guard let query = Self.shelfQuery(for: library) else { continue }
                group.addTask { (index, await capture { try await client.items(query) }) }
            }
            var collected: [(Int, Result<(items: [MediaItem], total: Int), any Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var shelves: [LibraryShelf] = []
        for (index, result) in results {
            let library = libraries[index]
            switch result {
            case .success(let page) where !page.items.isEmpty:
                shelves.append(LibraryShelf(library: library, items: MediaItemMerger.merge(page.items), total: page.total))
            case .success:
                break
            case .failure(let error):
                failures[library.name] = error.localizedDescription
            }
        }
        return shelves
    }

    /// 媒体库分区的查询；音乐、图书、播放列表、直播等不适合海报分区的库返回 nil。
    static func shelfQuery(for library: MediaItem) -> ItemQuery? {
        let (types, sort): ([String], ItemQuery.SortField)
        switch library.collectionType?.lowercased() {
        case "movies": (types, sort) = (["Movie"], .dateCreated)
        // 剧集按最近新增单集排序，追更的剧会排在前面。
        case "tvshows": (types, sort) = (["Series"], .dateLastContentAdded)
        case "boxsets": (types, sort) = (["BoxSet"], .dateCreated)
        case "homevideos": (types, sort) = (["Video"], .dateCreated)
        case "musicvideos": (types, sort) = (["MusicVideo"], .dateCreated)
        case nil, "mixed", "": (types, sort) = (["Movie", "Series"], .dateCreated)
        default: return nil
        }
        return ItemQuery(
            parentID: library.id,
            includeItemTypes: types,
            recursive: true,
            sortBy: sort,
            sortDescending: true,
            limit: shelfLimit
        )
    }

    /// 加载某个分类的风格分区：取该类型条目最多的若干风格，每个风格一行最新条目。
    func loadGenres(_ category: Category, client: MediaServerClient) async {
        guard let type = category.itemType, genreShelves[category]?.value == nil else { return }
        genreShelves[category] = .loading
        do {
            let genres = try await client.facets(.genres, parentID: nil, includeItemTypes: [type])
                .sorted { ($0.childCount ?? 0) > ($1.childCount ?? 0) }
                .prefix(Self.genreShelfLimit)
            let limit = Self.shelfLimit
            let shelves = await withTaskGroup(of: (Int, GenreShelf?).self) { group in
                for (index, genre) in genres.enumerated() {
                    group.addTask {
                        var query = ItemQuery(includeItemTypes: [type], recursive: true, sortBy: .dateCreated, sortDescending: true, limit: limit)
                        query.genreIDs = [genre.id]
                        // 单个风格失败只少一行，不影响其他风格。
                        guard let items = try? await client.items(query).items, !items.isEmpty else { return (index, nil) }
                        return (index, GenreShelf(genre: genre, items: MediaItemMerger.merge(items)))
                    }
                }
                var collected: [(Int, GenreShelf?)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            genreShelves[category] = .loaded(shelves)
        } catch {
            genreShelves[category] = .failed(error.localizedDescription)
        }
    }
}
