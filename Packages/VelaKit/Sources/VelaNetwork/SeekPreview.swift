import Foundation

public struct JellyfinTrickplayLayout: Decodable, Sendable {
    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    public let thumbnailCount: Int
    /// 相邻预览帧的时间间隔，单位为毫秒。
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case width = "Width"
        case height = "Height"
        case columns = "TileWidth"
        case rows = "TileHeight"
        case thumbnailCount = "ThumbnailCount"
        case interval = "Interval"
    }
}

public struct EmbySeekThumbnail: Decodable, Sendable {
    public let positionTicks: Int64
    public let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case imageTag = "ImageTag"
    }
}

extension MediaServerClient {
    public func trickplayLayouts(itemID: String, mediaSourceID: String) async throws -> [JellyfinTrickplayLayout] {
        struct Manifest: Decodable {
            let layouts: [String: [String: JellyfinTrickplayLayout]]?
            enum CodingKeys: String, CodingKey { case layouts = "Trickplay" }
        }
        let manifest = try await httpClient.decode(
            Manifest.self,
            APIRequest("/Users/\(userID)/Items/\(itemID)", query: [.init(name: "Fields", value: "Trickplay")], timeout: 3),
            baseURL: baseURL, headers: requestHeaders
        )
        let source = normalizedSourceID(mediaSourceID)
        guard let layouts = manifest.layouts?.first(where: { normalizedSourceID($0.key) == source })?.value else { return [] }
        return Array(layouts.values)
    }

    public func trickplayTile(itemID: String, mediaSourceID: String, width: Int, index: Int) async throws -> Data {
        try await seekPreviewData(
            "/Videos/\(itemID)/Trickplay/\(width)/\(index).jpg",
            query: [.init(name: "MediaSourceId", value: mediaSourceID)]
        )
    }

    public func embySeekThumbnails(itemID: String) async throws -> [EmbySeekThumbnail] {
        struct ThumbnailSet: Decodable {
            let thumbnails: [EmbySeekThumbnail]?
            enum CodingKeys: String, CodingKey { case thumbnails = "Thumbnails" }
        }
        return try await httpClient.decode(
            ThumbnailSet.self,
            APIRequest("/Items/\(itemID)/ThumbnailSet", timeout: 3),
            baseURL: baseURL, headers: requestHeaders
        ).thumbnails ?? []
    }

    public func embySeekThumbnail(itemID: String, mediaSourceID: String, thumbnail: EmbySeekThumbnail) async throws -> Data {
        var query: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: mediaSourceID),
            .init(name: "PositionTicks", value: String(thumbnail.positionTicks)),
            .init(name: "MaxWidth", value: "480")
        ]
        if let tag = thumbnail.imageTag { query.append(.init(name: "Tag", value: tag)) }
        return try await seekPreviewData("/Items/\(itemID)/Images/Thumbnail", query: query)
    }

    private func seekPreviewData(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var headers = requestHeaders
        headers["Accept"] = "image/jpeg,image/*"
        return try await httpClient.data(APIRequest(path, query: query, timeout: 3), baseURL: baseURL, headers: headers).0
    }

    private func normalizedSourceID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
