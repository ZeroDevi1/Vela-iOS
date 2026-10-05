import Foundation

/// TMDB 目录条目。目录条目不是库条目：它只描述一部作品，是否在某台服务器上有资源需另行按 provider id 精确匹配。
public struct CatalogTitle: Identifiable, Hashable, Sendable {
    public enum MediaType: String, Sendable, Hashable {
        case movie, tv
    }

    public var tmdbID: Int
    public var mediaType: MediaType
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    /// TMDB 图片相对路径，例如 `/abc.jpg`；用 `CatalogImage.url` 拼完整地址。
    public var posterPath: String?
    public var backdropPath: String?
    /// 上映 / 首播日期，`yyyy-MM-dd`。
    public var date: String?
    public var voteAverage: Double?
    public var genreIDs: [Int]

    /// 跨类型唯一：TMDB 的电影与剧集 id 空间独立。
    public var id: String { "\(mediaType.rawValue)/\(tmdbID)" }

    public var year: Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    public init(
        tmdbID: Int,
        mediaType: MediaType,
        title: String,
        originalTitle: String? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        date: String? = nil,
        voteAverage: Double? = nil,
        genreIDs: [Int] = []
    ) {
        self.tmdbID = tmdbID
        self.mediaType = mediaType
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.date = date
        self.voteAverage = voteAverage
        self.genreIDs = genreIDs
    }
}

/// TMDB 图片地址。
public enum CatalogImage {
    public enum Size: String, Sendable {
        case poster = "w342"
        case posterLarge = "w500"
        case backdrop = "w1280"
        case profile = "w185"
    }

    public static func url(_ path: String?, size: Size) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }
}

public enum CatalogCategory: String, CaseIterable, Sendable, Identifiable {
    case recommended, movies, series, animation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recommended: "推荐"
        case .movies: "电影"
        case .series: "剧集"
        case .animation: "动画"
        }
    }

    public var shelves: [CatalogShelf] {
        CatalogShelf.allCases.filter { $0.category == self }
    }
}

/// 发现页分区。与 Android 版 `CatalogShelf` 一一对应。
public enum CatalogShelf: String, CaseIterable, Sendable, Identifiable, Hashable {
    case day, week
    case popularMovies, topMovies, nowPlaying, upcoming, recentTop, classics
    case popularTV, topTV, airingToday, onAir, newTV
    case animationMovies, animationTV, animationTop

    public var id: String { rawValue }

    public var category: CatalogCategory {
        switch self {
        case .day, .week: .recommended
        case .popularMovies, .topMovies, .nowPlaying, .upcoming, .recentTop, .classics: .movies
        case .popularTV, .topTV, .airingToday, .onAir, .newTV: .series
        case .animationMovies, .animationTV, .animationTop: .animation
        }
    }

    /// 条目类型；nil 表示电影与剧集混合（趋势榜）。
    public var mediaType: CatalogTitle.MediaType? {
        switch self {
        case .day, .week: nil
        case .popularMovies, .topMovies, .nowPlaying, .upcoming, .recentTop, .classics, .animationMovies: .movie
        case .popularTV, .topTV, .airingToday, .onAir, .newTV, .animationTV, .animationTop: .tv
        }
    }

    public var title: String {
        switch self {
        case .day: "今日趋势"
        case .week: "本周趋势"
        case .popularMovies: "热门电影"
        case .topMovies: "高分电影"
        case .nowPlaying: "正在上映"
        case .upcoming: "即将上映"
        case .recentTop: "近年高分"
        case .classics: "经典电影"
        case .popularTV: "热门剧集"
        case .topTV: "高分剧集"
        case .airingToday: "今日播出"
        case .onAir: "正在播出"
        case .newTV: "新剧"
        case .animationMovies: "动画电影"
        case .animationTV: "热门动画"
        case .animationTop: "高分动画"
        }
    }

    /// 趋势榜与按日期的榜单不支持筛选（TMDB 对应接口没有筛选参数）。
    public var isFilterable: Bool {
        ![.day, .week, .nowPlaying, .upcoming].contains(self)
    }
}

/// 「查看全部」的筛选条件；全部为空表示使用分区默认排序。
public struct CatalogFilter: Hashable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        case popularity = "popularity.desc"
        case rating = "vote_average.desc"
        case newest = "date.desc"

        public var title: String {
            switch self {
            case .popularity: "热度"
            case .rating: "评分"
            case .newest: "最新"
            }
        }
    }

    public var genreID: Int?
    public var year: Int?
    public var sort: Sort?

    public init(genreID: Int? = nil, year: Int? = nil, sort: Sort? = nil) {
        self.genreID = genreID
        self.year = year
        self.sort = sort
    }

    public var isEmpty: Bool { genreID == nil && year == nil && sort == nil }
}

/// 分区 + 筛选 → TMDB 接口路径与参数。
public struct CatalogRequest: Equatable, Sendable {
    public var path: String
    public var parameters: [String: String]

    /// TMDB 动画类型 id。
    public static let animationGenreID = 16
    /// 按评分排序时的最少投票数，过滤只有几票的条目。
    static let ratingVoteFloor = "300"

    public static func make(shelf: CatalogShelf, filter: CatalogFilter = .init(), page: Int = 1, today: Date = .now) -> CatalogRequest {
        var request = base(shelf: shelf, today: today)
        if shelf.isFilterable, !filter.isEmpty, let type = shelf.mediaType {
            request = discover(from: request, type: type, filter: filter)
        }
        request.parameters["page"] = String(min(max(page, 1), 500))
        return request
    }

    private static func base(shelf: CatalogShelf, today: Date) -> CatalogRequest {
        let calendar = Calendar(identifier: .gregorian)
        func day(_ offset: DateComponents) -> String {
            let date = calendar.date(byAdding: offset, to: today) ?? today
            return date.formatted(.iso8601.year().month().day())
        }
        switch shelf {
        case .day: return .init(path: "trending/all/day", parameters: [:])
        case .week: return .init(path: "trending/all/week", parameters: [:])
        case .popularMovies: return .init(path: "movie/popular", parameters: [:])
        case .topMovies: return .init(path: "movie/top_rated", parameters: [:])
        case .nowPlaying: return .init(path: "movie/now_playing", parameters: [:])
        case .upcoming: return .init(path: "movie/upcoming", parameters: [:])
        case .recentTop:
            return .init(path: "discover/movie", parameters: [
                "sort_by": "vote_average.desc", "vote_count.gte": ratingVoteFloor,
                "primary_release_date.gte": day(DateComponents(year: -3))
            ])
        case .classics:
            return .init(path: "discover/movie", parameters: [
                "sort_by": "vote_average.desc", "vote_count.gte": "2000", "primary_release_date.lte": "1999-12-31"
            ])
        case .popularTV: return .init(path: "tv/popular", parameters: [:])
        case .topTV: return .init(path: "tv/top_rated", parameters: [:])
        case .airingToday: return .init(path: "tv/airing_today", parameters: [:])
        case .onAir: return .init(path: "tv/on_the_air", parameters: [:])
        case .newTV:
            return .init(path: "discover/tv", parameters: [
                "sort_by": "popularity.desc", "vote_count.gte": "20",
                "first_air_date.gte": day(DateComponents(month: -3))
            ])
        case .animationMovies:
            return .init(path: "discover/movie", parameters: ["sort_by": "popularity.desc", "with_genres": String(animationGenreID)])
        case .animationTV:
            return .init(path: "discover/tv", parameters: ["sort_by": "popularity.desc", "with_genres": String(animationGenreID)])
        case .animationTop:
            return .init(path: "discover/tv", parameters: [
                "sort_by": "vote_average.desc", "vote_count.gte": ratingVoteFloor, "with_genres": String(animationGenreID)
            ])
        }
    }

    /// 带筛选时统一走 discover 接口：保留分区原有的 discover 条件，榜单类分区换算成等价排序。
    private static func discover(from base: CatalogRequest, type: CatalogTitle.MediaType, filter: CatalogFilter) -> CatalogRequest {
        var parameters = base.path.hasPrefix("discover/") ? base.parameters : [:]
        if parameters["sort_by"] == nil {
            parameters["sort_by"] = base.path.hasSuffix("top_rated") ? "vote_average.desc" : "popularity.desc"
        }
        if let sort = filter.sort {
            switch sort {
            case .popularity: parameters["sort_by"] = "popularity.desc"
            case .rating: parameters["sort_by"] = "vote_average.desc"
            case .newest: parameters["sort_by"] = type == .movie ? "primary_release_date.desc" : "first_air_date.desc"
            }
        }
        if parameters["sort_by"] == "vote_average.desc", parameters["vote_count.gte"] == nil {
            parameters["vote_count.gte"] = ratingVoteFloor
        }
        if let genre = filter.genreID {
            // 动画分区再选类型时两者同时满足。
            let existing = parameters["with_genres"].map { $0 + "," } ?? ""
            parameters["with_genres"] = existing + String(genre)
        }
        if let year = filter.year {
            parameters[type == .movie ? "primary_release_year" : "first_air_date_year"] = String(year)
        }
        return .init(path: "discover/\(type.rawValue)", parameters: parameters)
    }
}

/// 目录条目的身份：TMDB id（必有）+ IMDb id（可选）。用于在服务器库中找同一作品。
///
/// 只认 provider id，不比较标题：同名作品很多，标题相似不能作为可播放的依据。
public struct CatalogIdentity: Hashable, Sendable {
    public var mediaType: CatalogTitle.MediaType
    public var tmdbID: Int
    public var imdbID: String?

    public init(mediaType: CatalogTitle.MediaType, tmdbID: Int, imdbID: String? = nil) {
        self.mediaType = mediaType
        self.tmdbID = tmdbID
        self.imdbID = imdbID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 发给服务器的 `AnyProviderIdEquals` 值，例如 `Tmdb.123,Imdb.tt456`。
    public var providerQuery: [String] {
        ["Tmdb.\(tmdbID)"] + (imdbID.map { ["Imdb.\($0)"] } ?? [])
    }

    /// 服务器可能忽略过滤参数，返回结果需逐条核对类型与 provider id。
    public func matches(_ item: MediaItem) -> Bool {
        let expectedKind: MediaItem.Kind = mediaType == .movie ? .movie : .series
        guard item.kind == expectedKind else { return false }
        if item.providerIDs["tmdb"] == String(tmdbID) { return true }
        if let imdbID, item.providerIDs["imdb"]?.caseInsensitiveCompare(imdbID) == .orderedSame { return true }
        return false
    }
}
