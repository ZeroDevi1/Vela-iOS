import Foundation

/// 服务器端在线字幕搜索结果（Jellyfin / Emby 的 `RemoteSubtitleInfo`）。
///
/// 搜索与下载都由服务器的字幕插件完成（如 OpenSubtitles），下载后字幕保存为该条目的外挂字幕，所有客户端可用。
/// 需要账号具备「字幕管理」权限，否则服务器返回 403。
public struct RemoteSubtitle: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var providerName: String?
    public var format: String?
    public var author: String?
    public var comment: String?
    public var downloadCount: Int?
    public var communityRating: Double?
    /// 按文件哈希精确匹配（与视频文件逐字节对应，时间轴最可靠）。
    public var isHashMatch: Bool?
    public var language: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", providerName = "ProviderName", format = "Format", author = "Author"
        case comment = "Comment", downloadCount = "DownloadCount", communityRating = "CommunityRating"
        case isHashMatch = "IsHashMatch", language = "ThreeLetterISOLanguageName"
    }
}

extension MediaServerClient {
    /// 在线搜索字幕。
    /// - Parameter language: ISO 639-2 三字母语言代码（`chi`、`eng` …），与服务器 `Language` 字段一致。
    public func searchRemoteSubtitles(itemID: String, mediaSourceID: String?, language: String) async throws -> [RemoteSubtitle] {
        var query: [URLQueryItem] = []
        // Emby 按版本区分（多版本条目时搜索对应文件的哈希）；Jellyfin 忽略该参数。
        if let mediaSourceID { query.append(.init(name: "MediaSourceId", value: mediaSourceID)) }
        return try await httpClient.decode(
            [RemoteSubtitle].self,
            // 字幕插件要逐个查询外部站点，响应较慢。
            APIRequest("/Items/\(itemID)/RemoteSearch/Subtitles/\(language)", query: query, timeout: 60),
            baseURL: baseURL,
            headers: requestHeaders
        )
    }

    /// 让服务器下载所选字幕并保存为该条目的外挂字幕。服务器随后刷新条目，新字幕要稍后才出现在媒体流列表中。
    public func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        let encoded = subtitleID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? subtitleID
        _ = try await httpClient.data(
            APIRequest("/Items/\(itemID)/RemoteSearch/Subtitles/\(encoded)", method: .post, timeout: 60),
            baseURL: baseURL,
            headers: requestHeaders
        )
    }
}
