import Foundation

/// `/Users/{id}/Items` 的查询条件。只暴露当前用到的参数，空值不会出现在请求里。
public struct ItemQuery: Sendable, Hashable {
    public enum SortField: String, Sendable {
        case name = "SortName"
        case dateCreated = "DateCreated"
        case premiereDate = "PremiereDate"
        case communityRating = "CommunityRating"
        case random = "Random"
        /// 剧集按最近新增单集的时间排序，用于「最近更新」。
        case dateLastContentAdded = "DateLastContentAdded"
        case productionYear = "ProductionYear"
        case criticRating = "CriticRating"
        case datePlayed = "DatePlayed"
        case playCount = "PlayCount"
        case officialRating = "OfficialRating"
    }

    public var parentID: String?
    public var searchTerm: String?
    public var includeItemTypes: [String]
    public var recursive: Bool
    public var sortBy: SortField?
    public var sortDescending: Bool
    public var startIndex: Int
    public var limit: Int?
    public var isFavorite: Bool?
    /// 只返回具有这些图片类型的条目（例如 `Backdrop`），用于轮播图。
    public var imageTypes: [String]
    /// 只返回这些人物参与的作品（演职人员详情页）。
    public var personIDs: [String]
    /// `IsPlayed`：true 只返回已看，false 只返回未看，nil 不筛选。
    public var isPlayed: Bool?
    /// `AnyProviderIdEquals`，例如 `["Tmdb.123", "Imdb.tt456"]`；服务器可能忽略，结果需调用方核对。
    public var anyProviderIDs: [String]
    /// 只返回这些风格 / 工作室下的条目。
    public var genreIDs: [String] = []
    public var studioIDs: [String] = []
    /// `CollapseBoxSetItems`：把属于合集的电影折叠为合集条目（Emby / Jellyfin 均支持）。
    public var collapseBoxSets = false

    public init(
        parentID: String? = nil,
        searchTerm: String? = nil,
        includeItemTypes: [String] = [],
        recursive: Bool = false,
        sortBy: SortField? = nil,
        sortDescending: Bool = false,
        startIndex: Int = 0,
        limit: Int? = nil,
        isFavorite: Bool? = nil,
        imageTypes: [String] = [],
        personIDs: [String] = [],
        isPlayed: Bool? = nil,
        anyProviderIDs: [String] = []
    ) {
        self.parentID = parentID
        self.searchTerm = searchTerm
        self.includeItemTypes = includeItemTypes
        self.recursive = recursive
        self.sortBy = sortBy
        self.sortDescending = sortDescending
        self.startIndex = startIndex
        self.limit = limit
        self.isFavorite = isFavorite
        self.imageTypes = imageTypes
        self.personIDs = personIDs
        self.isPlayed = isPlayed
        self.anyProviderIDs = anyProviderIDs
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let parentID { items.append(.init(name: "ParentId", value: parentID)) }
        if let searchTerm, !searchTerm.isEmpty { items.append(.init(name: "SearchTerm", value: searchTerm)) }
        if !includeItemTypes.isEmpty {
            items.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        if recursive { items.append(.init(name: "Recursive", value: "true")) }
        if let sortBy {
            // 主排序相同时按名称稳定排序，分页不会重复或漏项。
            items.append(.init(name: "SortBy", value: sortBy == .name ? sortBy.rawValue : "\(sortBy.rawValue),SortName"))
            items.append(.init(name: "SortOrder", value: sortDescending ? "Descending" : "Ascending"))
        }
        if startIndex > 0 { items.append(.init(name: "StartIndex", value: String(startIndex))) }
        if let limit { items.append(.init(name: "Limit", value: String(limit))) }
        if let isFavorite { items.append(.init(name: "IsFavorite", value: isFavorite ? "true" : "false")) }
        if !genreIDs.isEmpty { items.append(.init(name: "GenreIds", value: genreIDs.joined(separator: ","))) }
        if !studioIDs.isEmpty { items.append(.init(name: "StudioIds", value: studioIDs.joined(separator: ","))) }
        if !anyProviderIDs.isEmpty { items.append(.init(name: "AnyProviderIdEquals", value: anyProviderIDs.joined(separator: ","))) }
        if !personIDs.isEmpty { items.append(.init(name: "PersonIds", value: personIDs.joined(separator: ","))) }
        if let isPlayed { items.append(.init(name: "IsPlayed", value: isPlayed ? "true" : "false")) }
        if !imageTypes.isEmpty { items.append(.init(name: "ImageTypes", value: imageTypes.joined(separator: ","))) }
        if collapseBoxSets { items.append(.init(name: "CollapseBoxSetItems", value: "true")) }
        return items
    }
}
