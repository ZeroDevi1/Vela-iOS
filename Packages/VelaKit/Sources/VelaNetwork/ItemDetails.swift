import Foundation
import VelaCore

/// 详情页所需的完整条目信息：在 `MediaItem` 之外补充演职员、制片公司、媒体源等只有单条目接口才返回的字段。
public struct ItemDetails: Sendable {
    public struct Person: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// 角色名（演员）或职务。
        public var role: String?
        /// `Actor` / `Director` / `Writer` / `Producer` / `GuestStar` 等。
        public var type: String?
        public var primaryImageTag: String?
    }

    public var item: MediaItem
    public var people: [Person]
    public var studios: [String]
    public var taglines: [String]
    public var mediaSources: [MediaSourceInfo]
    /// 服务器上的文件路径（管理员可见；普通用户可能为空）。
    public var path: String?
    public var dateCreated: Date?
    /// 剧集状态：`Continuing` / `Ended`。
    public var seriesStatus: String?
    public var endDate: Date?
    /// 远程预告片（通常是 YouTube 链接），由刮削器提供，只能交给系统打开。
    public var remoteTrailers: [RemoteTrailer]
    /// 本地预告片数量；为 0 时不必请求 LocalTrailers 接口。
    public var localTrailerCount: Int
    /// 人物：出生地；作品：制作地区。
    public var productionLocations: [String]

    public struct RemoteTrailer: Identifiable, Hashable, Sendable {
        public var id: String { url.absoluteString }
        public var name: String?
        public var url: URL
    }
}

extension BaseItemDTO {
    func toDetails(serverID: String) -> ItemDetails {
        ItemDetails(
            item: toMediaItem(serverID: serverID),
            people: (people ?? []).map {
                .init(id: $0.id, name: $0.name, role: $0.role, type: $0.type, primaryImageTag: $0.primaryImageTag)
            },
            studios: (studios ?? []).map(\.name),
            taglines: taglines ?? [],
            mediaSources: mediaSources ?? [],
            path: path,
            dateCreated: dateCreated,
            seriesStatus: status,
            endDate: endDate,
            remoteTrailers: (remoteTrailers ?? []).compactMap { dto in
                URL(string: dto.url).map { .init(name: dto.name, url: $0) }
            },
            localTrailerCount: localTrailerCount ?? 0,
            productionLocations: productionLocations ?? []
        )
    }
}

extension MediaServerClient {
    /// 单条目完整信息。显式请求 Fields：Emby 单条目接口默认不返回 People / MediaSources 等字段。
    public func itemDetails(id: String) async throws -> ItemDetails {
        let dto = try await httpClient.decode(
            BaseItemDTO.self,
            APIRequest("/Users/\(userID)/Items/\(id)", query: [
                .init(name: "Fields", value: "People,Studios,Taglines,MediaSources,MediaStreams,Chapters,ProviderIds,Overview,Genres,DateCreated,Path,PremiereDate,ParentLogoItemId,ParentLogoImageTag,RemoteTrailers,LocalTrailerCount,ProductionLocations,EndDate,Tags,Video3DFormat,PartCount")
            ]),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return dto.toDetails(serverID: serverID)
    }

    /// 本地预告片与花絮（幕后、删减片段等），二者都是可直接播放的条目。
    ///
    /// 使用 `/Users/{userId}/Items/{id}/...` 路径：Emby 只支持此路径；Jellyfin 10.9 起改为
    /// `/Items/{id}/...?userId=`，旧路径在新版本可能 404，此时回退到新路径。
    public func localTrailers(itemID: String) async throws -> [MediaItem] {
        try await extras(itemID: itemID, kind: "LocalTrailers")
    }

    public func specialFeatures(itemID: String) async throws -> [MediaItem] {
        try await extras(itemID: itemID, kind: "SpecialFeatures")
    }

    private func extras(itemID: String, kind: String) async throws -> [MediaItem] {
        do {
            return try await decodeExtras(APIRequest("/Users/\(userID)/Items/\(itemID)/\(kind)"))
        } catch APIError.http(status: 404, _) where self.kind == .jellyfin {
            return try await decodeExtras(APIRequest("/Items/\(itemID)/\(kind)", query: [.init(name: "userId", value: userID)]))
        }
    }

    private func decodeExtras(_ request: APIRequest) async throws -> [MediaItem] {
        try await httpClient.decode([BaseItemDTO].self, request, baseURL: baseURL, headers: requestHeaders)
            .map { $0.toMediaItem(serverID: serverID) }
    }

    /// 媒体库内的风格 / 工作室（媒体库页的「风格」「工作室」分段）。
    public enum Facet: String, Sendable {
        case genres = "Genres"
        case studios = "Studios"
    }

    /// - Parameters:
    ///   - parentID: 限定媒体库；nil 表示全部库（首页「电影」「剧集」分类按风格分区）。
    ///   - includeItemTypes: 只统计含这些类型条目的风格，例如 `["Movie"]`；空数组不限制。
    public func facets(_ facet: Facet, parentID: String?, includeItemTypes: [String] = []) async throws -> [MediaItem] {
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: userID),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,ChildCount")
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        if !includeItemTypes.isEmpty { query.append(.init(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ","))) }
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/\(facet.rawValue)", query: query),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    /// 多段文件（CD1 / CD2 …）的附加段，不含主条目本身，按段顺序排列。
    public func additionalParts(itemID: String) async throws -> [MediaItem] {
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Videos/\(itemID)/AdditionalParts", query: [
                .init(name: "UserId", value: userID),
                .init(name: "Fields", value: Self.listFields)
            ]),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    public func seasons(seriesID: String) async throws -> [MediaItem] {
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/\(seriesID)/Seasons", query: [
                .init(name: "UserId", value: userID),
                .init(name: "Fields", value: "ChildCount,PrimaryImageAspectRatio")
            ]),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    /// 某一季的单集；`seasonID` 为 nil 时返回全剧。
    public func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem] {
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: userID),
            .init(name: "Fields", value: "Overview,ParentBackdropItemId,ParentBackdropImageTags")
        ]
        if let seasonID { query.append(.init(name: "SeasonId", value: seasonID)) }
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/\(seriesID)/Episodes", query: query),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    /// 批量下载用：某一季（`seasonID` 为 nil 时全剧）的单集及其第一个媒体源（文件大小、码率、音轨），
    /// 用于下载前估算占用空间与选择音轨。
    public func episodesWithMediaSources(seriesID: String, seasonID: String?) async throws -> [ItemWithMediaSource] {
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: userID),
            .init(name: "Fields", value: "MediaSources,ParentBackdropItemId,ParentBackdropImageTags")
        ]
        if let seasonID { query.append(.init(name: "SeasonId", value: seasonID)) }
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/\(seriesID)/Episodes", query: query),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.map { ItemWithMediaSource(item: $0.toMediaItem(serverID: serverID), source: $0.mediaSources?.first) }
    }

    public func similarItems(itemID: String, limit: Int = 20) async throws -> [MediaItem] {
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Items/\(itemID)/Similar", query: [
                .init(name: "UserId", value: userID),
                .init(name: "Limit", value: String(limit)),
                .init(name: "Fields", value: Self.listFields)
            ]),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    /// 剧集的「下一集」（未看完的第一集）；全部看完时返回 nil。
    public func nextUp(seriesID: String) async throws -> MediaItem? {
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/NextUp", query: [
                .init(name: "UserId", value: userID),
                .init(name: "SeriesId", value: seriesID),
                .init(name: "Limit", value: "1"),
                .init(name: "Fields", value: Self.listFields)
            ] + nextUpCompatibilityQuery),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return result.items.first?.toMediaItem(serverID: serverID)
    }

    public func setPlayed(itemID: String, _ played: Bool) async throws {
        _ = try await httpClient.data(
            APIRequest("/Users/\(userID)/PlayedItems/\(itemID)", method: played ? .post : .delete),
            baseURL: baseURL,
            headers: requestHeaders
        )
    }

    public func setFavorite(itemID: String, _ favorite: Bool) async throws {
        _ = try await httpClient.data(
            APIRequest("/Users/\(userID)/FavoriteItems/\(itemID)", method: favorite ? .post : .delete),
            baseURL: baseURL,
            headers: requestHeaders
        )
    }

    /// 让服务器重新扫描文件并刷新元数据（不替换已有图片与元数据，只补缺）。需要管理员权限，否则服务器返回 401 / 403。
    public func refreshMetadata(itemID: String) async throws {
        _ = try await httpClient.data(
            APIRequest("/Items/\(itemID)/Refresh", method: .post, query: [
                .init(name: "Recursive", value: "true"),
                .init(name: "MetadataRefreshMode", value: "Default"),
                .init(name: "ImageRefreshMode", value: "Default"),
                .init(name: "ReplaceAllMetadata", value: "false"),
                .init(name: "ReplaceAllImages", value: "false")
            ]),
            baseURL: baseURL,
            headers: requestHeaders
        )
    }

    // MARK: - 图片

    public func personImageURL(_ person: ItemDetails.Person, maxWidth: Int) -> URL? {
        guard let tag = person.primaryImageTag else { return nil }
        return imageURL(itemID: person.id, path: "Primary", tag: tag, maxWidth: maxWidth)
    }

    /// 条目自己的全部背景图（剧照），按服务器顺序；不回退到父级。用于详情页「剧照」分区。
    public func backdropImageURLs(for item: MediaItem, maxWidth: Int) -> [URL] {
        item.backdropImageTags.enumerated().compactMap { index, tag in
            imageURL(itemID: item.id, path: "Backdrop/\(index)", tag: tag, maxWidth: maxWidth)
        }
    }

    public func chapterImageURL(itemID: String, index: Int, chapter: MediaChapter, maxWidth: Int) -> URL? {
        guard let tag = chapter.imageTag else { return nil }
        return imageURL(itemID: itemID, path: "Chapter/\(index)", tag: tag, maxWidth: maxWidth)
    }

    /// 条目自己的 Logo，没有时回退到剧的 Logo。
    /// 只知道条目 id、没有图片 tag 时的主图地址（如单集所属剧集的海报）。服务器没有该图时返回 404，由图片组件显示占位。
    public func primaryImageURL(itemID: String, maxWidth: Int) -> URL? {
        try? HTTPClient.makeURL(
            baseURL: baseURL,
            path: "/Items/\(itemID)/Images/Primary",
            query: [.init(name: "maxWidth", value: String(maxWidth)), .init(name: "quality", value: "90")]
        )
    }

    public func logoURL(for item: MediaItem, maxWidth: Int) -> URL? {
        if let tag = item.imageTags[.logo] {
            return imageURL(itemID: item.id, path: "Logo", tag: tag, maxWidth: maxWidth)
        }
        if let parent = item.parentLogoItemID, let tag = item.parentLogoImageTag {
            return imageURL(itemID: parent, path: "Logo", tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    private func imageURL(itemID: String, path: String, tag: String, maxWidth: Int) -> URL? {
        try? HTTPClient.makeURL(
            baseURL: baseURL,
            path: "/Items/\(itemID)/Images/\(path)",
            query: [
                .init(name: "tag", value: tag),
                .init(name: "maxWidth", value: String(maxWidth)),
                .init(name: "quality", value: "90")
            ]
        )
    }
}

/// 条目与其第一个媒体源（服务器未返回时为 nil）。
public struct ItemWithMediaSource: Sendable, Identifiable {
    public var item: MediaItem
    public var source: MediaSourceInfo?
    public var id: String { item.id }
}
