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
            endDate: endDate
        )
    }
}

extension MediaServerClient {
    /// 单条目完整信息。显式请求 Fields：Emby 单条目接口默认不返回 People / MediaSources 等字段。
    public func itemDetails(id: String) async throws -> ItemDetails {
        let dto = try await httpClient.decode(
            BaseItemDTO.self,
            APIRequest("/Users/\(userID)/Items/\(id)", query: [
                .init(name: "Fields", value: "People,Studios,Taglines,MediaSources,MediaStreams,Chapters,ProviderIds,Overview,Genres,DateCreated,Path,PremiereDate,ParentLogoItemId,ParentLogoImageTag")
            ]),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return dto.toDetails(serverID: serverID)
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
            ]),
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

    // MARK: - 图片

    public func personImageURL(_ person: ItemDetails.Person, maxWidth: Int) -> URL? {
        guard let tag = person.primaryImageTag else { return nil }
        return imageURL(itemID: person.id, path: "Primary", tag: tag, maxWidth: maxWidth)
    }

    public func chapterImageURL(itemID: String, index: Int, chapter: MediaChapter, maxWidth: Int) -> URL? {
        guard let tag = chapter.imageTag else { return nil }
        return imageURL(itemID: itemID, path: "Chapter/\(index)", tag: tag, maxWidth: maxWidth)
    }

    /// 条目自己的 Logo，没有时回退到剧的 Logo。
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
