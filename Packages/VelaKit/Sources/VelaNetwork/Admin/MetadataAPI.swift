import Foundation
import VelaCore

/// 可编辑的基本元数据（与 Android 元数据编辑页相同的字段）。服务器的条目更新接口要求提交完整条目，
/// 所以编辑时读取原始 JSON、只替换这些字段后整份回写，其余字段（演职员、图片、外部 id 等）原样保留。
public struct EditableMetadata: Equatable, Sendable {
    public var name: String
    public var originalTitle: String
    public var sortName: String
    public var overview: String
    public var productionYear: Int?
    public var premiereDate: Date?
    public var officialRating: String
    public var communityRating: Double?
    public var genres: [String]
    public var tags: [String]
    public var studios: [String]
    /// 锁定后服务器刷新元数据时不再覆盖。
    public var lockData: Bool

    init(json: [String: Any]) {
        name = json["Name"] as? String ?? ""
        originalTitle = json["OriginalTitle"] as? String ?? ""
        sortName = json["ForcedSortName"] as? String ?? json["SortName"] as? String ?? ""
        overview = json["Overview"] as? String ?? ""
        productionYear = json["ProductionYear"] as? Int
        premiereDate = (json["PremiereDate"] as? String).flatMap(Self.parseDate)
        officialRating = json["OfficialRating"] as? String ?? ""
        communityRating = (json["CommunityRating"] as? NSNumber)?.doubleValue
        genres = json["Genres"] as? [String] ?? []
        tags = json["Tags"] as? [String] ?? []
        studios = (json["Studios"] as? [[String: Any]])?.compactMap { $0["Name"] as? String } ?? []
        lockData = json["LockData"] as? Bool ?? false
    }

    /// 写回原始 JSON：只替换编辑过的字段。空字符串表示清除。
    func apply(to json: inout [String: Any]) {
        json["Name"] = name
        json["OriginalTitle"] = originalTitle.isEmpty ? nil : originalTitle
        json["ForcedSortName"] = sortName.isEmpty ? nil : sortName
        json["Overview"] = overview.isEmpty ? nil : overview
        json["ProductionYear"] = productionYear
        json["PremiereDate"] = premiereDate.map { $0.formatted(.iso8601) }
        json["OfficialRating"] = officialRating.isEmpty ? nil : officialRating
        json["CommunityRating"] = communityRating
        json["Genres"] = genres
        json["Tags"] = tags
        let existing = (json["Studios"] as? [[String: Any]]) ?? []
        json["Studios"] = studios.map { name in existing.first { $0["Name"] as? String == name } ?? ["Name": name] }
        json["LockData"] = lockData
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        // 服务器有时返回 7 位小数秒，ISO 8601 解析器不认：截到秒再解析。
        guard text.count >= 19 else { return nil }
        return try? Date(String(text.prefix(19)) + "Z", strategy: .iso8601)
    }
}

/// 识别（远程搜索）的一个候选。`raw` 为服务器返回的原始对象，应用时原样提交。
public struct RemoteMetadataResult: Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var year: Int?
    public var overview: String?
    public var imageURL: URL?
    public var providerName: String?
    public var providerIDs: [String: String]
    let raw: Data
}

/// 条目上已有的一张图片。
public struct ItemImageInfo: Decodable, Identifiable, Sendable {
    public var type: String
    public var index: Int?
    public var tag: String?
    public var width: Int?
    public var height: Int?
    public var id: String { "\(type)-\(index ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case type = "ImageType", index = "ImageIndex", tag = "ImageTag", width = "Width", height = "Height"
    }
}

/// 远程图片（元数据提供方给出的候选）。
public struct RemoteImageInfo: Decodable, Identifiable, Sendable {
    public var url: String
    public var thumbnailURL: String?
    public var providerName: String?
    public var width: Int?
    public var height: Int?
    public var language: String?
    public var communityRating: Double?
    public var id: String { url }

    enum CodingKeys: String, CodingKey {
        case url = "Url", thumbnailURL = "ThumbnailUrl", providerName = "ProviderName", width = "Width"
        case height = "Height", language = "Language", communityRating = "CommunityRating"
    }
}

/// 远程图片查询结果：候选图片与本次可选的提供方（用于按提供方筛选）。
public struct RemoteImagesResult: Decodable, Sendable {
    public var images: [RemoteImageInfo]
    public var providers: [String]
    public var totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case images = "Images", providers = "Providers", totalRecordCount = "TotalRecordCount"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeIfPresent([RemoteImageInfo].self, forKey: .images) ?? []
        providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }
}

/// 条目支持的外部 ID（`GET /Items/{id}/ExternalIdInfos`）。识别表单按它生成输入框，插件提供方（如 MetaTube）也能按 ID 搜索。
public struct ExternalIDInfo: Decodable, Identifiable, Sendable {
    public var name: String?
    /// 提供方键，即 `ProviderIds` 中的键（如 `Tmdb`）。
    public var key: String?
    /// Jellyfin：ID 所属的实体类型（如 Movie、Series），用于区分同名提供方。
    public var type: String?
    /// Emby：为 false 时该 ID 不能用于识别。
    public var isSupportedAsIdentifier: Bool?
    public var id: String { key ?? name ?? "" }

    public init(name: String?, key: String?, type: String? = nil, isSupportedAsIdentifier: Bool? = nil) {
        self.name = name
        self.key = key
        self.type = type
        self.isSupportedAsIdentifier = isSupportedAsIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name", key = "Key", type = "Type", isSupportedAsIdentifier = "IsSupportedAsIdentifier"
    }
}

extension MediaServerClient {
    // MARK: - 编辑

    /// 读取条目的原始 JSON（用于整份回写）。
    func itemJSON(itemID: String) async throws -> [String: Any] {
        let (data, _) = try await httpClient.data(APIRequest("/Users/\(userID)/Items/\(itemID)"), baseURL: baseURL, headers: requestHeaders)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.http(status: -1, body: nil) }
        return json
    }

    public func editableMetadata(itemID: String) async throws -> EditableMetadata {
        EditableMetadata(json: try await itemJSON(itemID: itemID))
    }

    /// 保存基本元数据：重新读取最新的条目 JSON，只替换编辑字段后提交，避免覆盖其他客户端在此期间的修改。
    public func updateMetadata(itemID: String, _ metadata: EditableMetadata) async throws {
        var json = try await itemJSON(itemID: itemID)
        metadata.apply(to: &json)
        let body = try JSONSerialization.data(withJSONObject: json)
        _ = try await httpClient.data(APIRequest("/Items/\(itemID)", method: .post, body: body), baseURL: baseURL, headers: requestHeaders)
    }

    /// 增删条目标签（不区分大小写比较），其余元数据原样保留；需要管理员权限，否则服务器返回 403。
    /// 结果与现有标签相同时不提交。
    public func updateTags(itemID: String, adding: [String], removing: [String]) async throws {
        var json = try await itemJSON(itemID: itemID)
        let existing = json["Tags"] as? [String] ?? []
        let merged = Self.mergedTags(existing, adding: adding, removing: removing)
        guard merged != existing else { return }
        json["Tags"] = merged
        let body = try JSONSerialization.data(withJSONObject: json)
        _ = try await httpClient.data(APIRequest("/Items/\(itemID)", method: .post, body: body), baseURL: baseURL, headers: requestHeaders)
    }

    /// 先去掉 `removing`，再把 `adding` 中尚不存在的追加到末尾；保留原有标签的顺序与大小写。
    static func mergedTags(_ existing: [String], adding: [String], removing: [String]) -> [String] {
        let removed = Set(removing.map { $0.lowercased() })
        var result = existing.filter { !removed.contains($0.lowercased()) }
        for tag in adding where !result.contains(where: { $0.lowercased() == tag.lowercased() }) {
            result.append(tag)
        }
        return result
    }

    /// 刷新元数据；`replaceAll` 为 true 时替换全部元数据与图片（锁定字段除外）。
    public func refreshMetadata(itemID: String, replaceAll: Bool) async throws {
        let mode = replaceAll ? "FullRefresh" : "Default"
        _ = try await httpClient.data(APIRequest("/Items/\(itemID)/Refresh", method: .post, query: [
            .init(name: "Recursive", value: "true"),
            .init(name: "MetadataRefreshMode", value: mode),
            .init(name: "ImageRefreshMode", value: mode),
            .init(name: "ReplaceAllMetadata", value: replaceAll ? "true" : "false"),
            .init(name: "ReplaceAllImages", value: replaceAll ? "true" : "false"),
        ]), baseURL: baseURL, headers: requestHeaders)
    }

    // MARK: - 识别

    /// 远程搜索路径段：电影 `Movie`、剧集 `Series`、单集 `Episode`、合集 `BoxSet`…；不支持识别的类型为 nil。
    public static func remoteSearchType(for kind: MediaItem.Kind) -> String? {
        switch kind {
        case .movie: "Movie"
        case .series: "Series"
        case .boxSet: "BoxSet"
        case .musicVideo: "MusicVideo"
        case .person: "Person"
        default: nil
        }
    }

    /// 条目可用于识别的外部 ID 类型；Emby 标记为不可识别的、以及没有键的项已排除。
    public func externalIDInfos(itemID: String) async throws -> [ExternalIDInfo] {
        try await httpClient.decode([ExternalIDInfo].self, APIRequest("/Items/\(itemID)/ExternalIdInfos"), baseURL: baseURL, headers: requestHeaders)
            .filter { !($0.key ?? "").isEmpty && $0.isSupportedAsIdentifier != false }
    }

    /// 用名称 / 年份 / 外部 id 向服务器的元数据提供方搜索候选。
    public func remoteMetadataSearch(
        itemID: String, kind: MediaItem.Kind, name: String, year: Int?, providerIDs: [String: String]
    ) async throws -> [RemoteMetadataResult] {
        guard let type = Self.remoteSearchType(for: kind) else { return [] }
        var info: [String: Any] = ["Name": name]
        if let year { info["Year"] = year }
        let ids = providerIDs.filter { !$0.value.isEmpty }
        if !ids.isEmpty { info["ProviderIds"] = ids }
        let body = try JSONSerialization.data(withJSONObject: ["ItemId": itemID, "SearchInfo": info])
        let (data, _) = try await httpClient.data(
            APIRequest("/Items/RemoteSearch/\(type)", method: .post, body: body, timeout: 60),
            baseURL: baseURL, headers: requestHeaders
        )
        return try Self.parseRemoteSearch(data)
    }

    static func parseRemoteSearch(_ data: Data) throws -> [RemoteMetadataResult] {
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return try list.enumerated().map { index, object in
            RemoteMetadataResult(
                id: index,
                name: object["Name"] as? String ?? "",
                year: object["ProductionYear"] as? Int,
                overview: object["Overview"] as? String,
                imageURL: (object["ImageUrl"] as? String).flatMap(URL.init(string:)),
                providerName: object["SearchProviderName"] as? String,
                providerIDs: object["ProviderIds"] as? [String: String] ?? [:],
                raw: try JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    /// 应用识别结果；服务器随即按新的外部 id 刷新元数据。
    public func applyRemoteMetadata(itemID: String, result: RemoteMetadataResult, replaceAllImages: Bool) async throws {
        _ = try await httpClient.data(
            APIRequest("/Items/RemoteSearch/Apply/\(itemID)", method: .post,
                       query: [.init(name: "ReplaceAllImages", value: replaceAllImages ? "true" : "false")],
                       body: result.raw, timeout: 60),
            baseURL: baseURL, headers: requestHeaders
        )
    }

    // MARK: - 图片

    public func itemImages(itemID: String) async throws -> [ItemImageInfo] {
        try await httpClient.decode([ItemImageInfo].self, APIRequest("/Items/\(itemID)/Images"), baseURL: baseURL, headers: requestHeaders)
    }

    /// 远程候选图片；`type` 为 `Primary` / `Backdrop` / `Logo` / `Thumb` 等，`providerName` 为 nil 时查询全部提供方。
    public func remoteImages(
        itemID: String, type: String, providerName: String?, allLanguages: Bool,
        startIndex: Int = 0, limit: Int? = nil
    ) async throws -> RemoteImagesResult {
        var query: [URLQueryItem] = [
            .init(name: "Type", value: type),
            .init(name: "IncludeAllLanguages", value: allLanguages ? "true" : "false"),
        ]
        if let providerName { query.append(.init(name: "ProviderName", value: providerName)) }
        if startIndex > 0 { query.append(.init(name: "StartIndex", value: String(startIndex))) }
        if let limit { query.append(.init(name: "Limit", value: String(limit))) }
        return try await httpClient.decode(
            RemoteImagesResult.self,
            APIRequest("/Items/\(itemID)/RemoteImages", query: query, timeout: 60),
            baseURL: baseURL, headers: requestHeaders
        )
    }

    /// 上传本地图片设为该类型的图片（背景图为追加）。服务器要求请求体为 Base64 文本、`Content-Type` 为图片类型。
    /// - Parameter mimeType: 例如 `image/jpeg`、`image/png`。
    public func uploadImage(itemID: String, type: String, data: Data, mimeType: String) async throws {
        let body = Data(data.base64EncodedString().utf8)
        var headers = requestHeaders
        headers["Content-Type"] = mimeType
        _ = try await httpClient.data(
            APIRequest("/Items/\(itemID)/Images/\(type)", method: .post, body: body, timeout: 120),
            baseURL: baseURL, headers: headers
        )
    }

    /// 让服务器下载远程图片并设为该类型的图片（背景图为追加）。
    public func downloadRemoteImage(itemID: String, type: String, image: RemoteImageInfo) async throws {
        var query: [URLQueryItem] = [.init(name: "Type", value: type), .init(name: "ImageUrl", value: image.url)]
        if let provider = image.providerName { query.append(.init(name: "ProviderName", value: provider)) }
        _ = try await httpClient.data(
            APIRequest("/Items/\(itemID)/RemoteImages/Download", method: .post, query: query, timeout: 60),
            baseURL: baseURL, headers: requestHeaders
        )
    }

    public func deleteImage(itemID: String, type: String, index: Int?) async throws {
        let path = index.map { "/Items/\(itemID)/Images/\(type)/\($0)" } ?? "/Items/\(itemID)/Images/\(type)"
        _ = try await httpClient.data(APIRequest(path, method: .delete), baseURL: baseURL, headers: requestHeaders)
    }

    /// 调整同类型图片的服务器索引；Jellyfin 会交换两个位置。
    public func updateImageIndex(itemID: String, type: String, index: Int, newIndex: Int) async throws {
        _ = try await httpClient.data(
            APIRequest("/Items/\(itemID)/Images/\(type)/\(index)/Index", method: .post,
                       query: [.init(name: "NewIndex", value: String(newIndex))]),
            baseURL: baseURL, headers: requestHeaders
        )
    }

    /// 图片地址（带 tag 以绕过缓存）。
    public func imageURL(itemID: String, image: ItemImageInfo, maxWidth: Int) -> URL? {
        var path = "/Items/\(itemID)/Images/\(image.type)"
        if let index = image.index { path += "/\(index)" }
        var query: [URLQueryItem] = [.init(name: "maxWidth", value: String(maxWidth))]
        if let tag = image.tag { query.append(.init(name: "tag", value: tag)) }
        return try? HTTPClient.makeURL(baseURL: baseURL, path: path, query: query)
    }

    // MARK: - 字幕

    /// 删除外挂字幕（只能删除外挂字幕，内嵌字幕属于视频文件）。Emby 的路径带媒体源 id。
    public func deleteSubtitle(itemID: String, mediaSourceID: String?, streamIndex: Int) async throws {
        let path = kind == .emby
            ? "/Videos/\(itemID)/\(mediaSourceID ?? itemID)/Subtitles/\(streamIndex)"
            : "/Videos/\(itemID)/Subtitles/\(streamIndex)"
        _ = try await httpClient.data(APIRequest(path, method: .delete), baseURL: baseURL, headers: requestHeaders)
    }
}
