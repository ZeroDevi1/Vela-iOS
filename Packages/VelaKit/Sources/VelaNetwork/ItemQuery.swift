import Foundation

/// `/Users/{id}/Items` 的查询条件。只暴露当前用到的参数，空值不会出现在请求里。
public struct ItemQuery: Sendable, Hashable {
    public enum SortField: String, Sendable {
        case name = "SortName"
        case dateCreated = "DateCreated"
        case premiereDate = "PremiereDate"
        case communityRating = "CommunityRating"
        case random = "Random"
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

    public init(
        parentID: String? = nil,
        searchTerm: String? = nil,
        includeItemTypes: [String] = [],
        recursive: Bool = false,
        sortBy: SortField? = nil,
        sortDescending: Bool = false,
        startIndex: Int = 0,
        limit: Int? = nil,
        isFavorite: Bool? = nil
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
            items.append(.init(name: "SortBy", value: sortBy.rawValue))
            items.append(.init(name: "SortOrder", value: sortDescending ? "Descending" : "Ascending"))
        }
        if startIndex > 0 { items.append(.init(name: "StartIndex", value: String(startIndex))) }
        if let limit { items.append(.init(name: "Limit", value: String(limit))) }
        if let isFavorite { items.append(.init(name: "IsFavorite", value: isFavorite ? "true" : "false")) }
        return items
    }
}
