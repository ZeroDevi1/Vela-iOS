import Foundation

/// MoviePilot 的一条订阅。订阅列表每次从服务端读取，客户端不缓存第二份真相源。
public struct SubscriptionRecord: Identifiable, Hashable, Sendable {
    /// MoviePilot 订阅行 id；删除按行 id，避免电影 / 剧集 TMDB id 空间冲突。
    public var id: Int
    public var name: String
    public var posterURL: URL?
    public var mediaType: CatalogTitle.MediaType?
    /// 剧集订阅的季号；电影为 nil。
    public var season: Int?
    public var tmdbID: Int?
    public var year: String?
    /// MoviePilot 状态：`N` 新建、`R` 订阅中、`P` 待定、`S` 暂停等。
    public var state: String?
    public var totalEpisodes: Int?
    /// 尚缺集数（MoviePilot `lack_episode`）。
    public var lackEpisodes: Int?
    public var episodeGroup: String?

    public init(
        id: Int, name: String, posterURL: URL? = nil, mediaType: CatalogTitle.MediaType? = nil, season: Int? = nil,
        tmdbID: Int? = nil, year: String? = nil, state: String? = nil, totalEpisodes: Int? = nil,
        lackEpisodes: Int? = nil, episodeGroup: String? = nil
    ) {
        self.id = id
        self.name = name
        self.posterURL = posterURL
        self.mediaType = mediaType
        self.season = season
        self.tmdbID = tmdbID
        self.year = year
        self.state = state
        self.totalEpisodes = totalEpisodes
        self.lackEpisodes = lackEpisodes
        self.episodeGroup = episodeGroup
    }

    /// 对应的目录条目（有 TMDB 身份时）；用于进入目录详情与匹配库资源。
    public var catalogTitle: CatalogTitle? {
        guard let tmdbID, let mediaType else { return nil }
        return CatalogTitle(tmdbID: tmdbID, mediaType: mediaType, title: name, date: year.map { "\($0)-01-01" })
    }

    public var stateText: String {
        switch state {
        case "N": "新建"
        case "R": "订阅中"
        case "P": "待定"
        case "S": "已暂停"
        default: state ?? ""
        }
    }

    /// MoviePilot 用中文类型名。
    public static func mediaType(fromMoviePilot raw: String?) -> CatalogTitle.MediaType? {
        switch raw {
        case "电影", "movie": .movie
        case "电视剧", "tv": .tv
        default: nil
        }
    }
}

/// 日历中的一条：某部作品在某天播出 / 上映。
public struct CalendarEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var originalTitle: String?
    public var posterURL: URL?
    /// 播出日（当地日历日，时间部分无意义）。
    public var date: Date
    public var catalog: CatalogTitle?
    public var season: Int?
    public var episode: Int?
    public var episodeName: String?
    /// Bangumi 条目页等外部地址。
    public var sourceURL: URL?

    public init(
        id: String, title: String, originalTitle: String? = nil, posterURL: URL? = nil, date: Date,
        catalog: CatalogTitle? = nil, season: Int? = nil, episode: Int? = nil, episodeName: String? = nil, sourceURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.posterURL = posterURL
        self.date = date
        self.catalog = catalog
        self.season = season
        self.episode = episode
        self.episodeName = episodeName
        self.sourceURL = sourceURL
    }

    /// 「S01E05 · 标题」；电影 / Bangumi 条目为 nil。
    public var episodeLabel: String? {
        guard let episode else { return nil }
        let code = (season.map { String(format: "S%02d", $0) } ?? "") + String(format: "E%02d", episode)
        return [code, episodeName].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct CalendarFeed: Sendable {
    /// 「MoviePilot」或「Bangumi」。
    public var source: String
    public var entries: [CalendarEntry]
    /// 部分失败或回退时的说明。
    public var warning: String?

    public init(source: String, entries: [CalendarEntry], warning: String? = nil) {
        self.source = source
        self.entries = entries
        self.warning = warning
    }
}

/// 日历的日期规则。
public enum CalendarRules {
    /// MoviePilot 日历展示窗口：过去 7 天到未来 30 天。
    public static let pastDays = 7
    public static let futureDays = 30

    /// 解析 `yyyy-MM-dd`（可带时间部分）为当地日历日。
    public static func day(from raw: String?, calendar: Calendar = .current) -> Date? {
        guard let raw, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func isInWindow(_ date: Date, today: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: today)
        guard let lower = calendar.date(byAdding: .day, value: -pastDays, to: start),
              let upper = calendar.date(byAdding: .day, value: futureDays, to: start) else { return false }
        return date >= lower && date <= upper
    }

    /// Bangumi 公开日历只给星期（1 = 周一 … 7 = 周日）：映射到从今天起的 7 天内，不伪造过去的播出历史。
    public static func nextDate(forBangumiWeekday weekday: Int, today: Date, calendar: Calendar = .current) -> Date? {
        guard (1...7).contains(weekday) else { return nil }
        let start = calendar.startOfDay(for: today)
        // Foundation：1 = 周日 … 7 = 周六；换算为 1 = 周一 … 7 = 周日。
        let todayWeekday = (calendar.component(.weekday, from: start) + 5) % 7 + 1
        let offset = (weekday - todayWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: start)
    }
}
