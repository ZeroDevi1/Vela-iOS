import Foundation
import VelaCore

/// 服务器「推荐」接口（搜索页未输入时的大海报）的请求构造。Jellyfin 与 Emby 的路径和参数名不同，
/// 各自实现一个 provider，由 `MediaServerClient.suggestions` 按服务器类型选择。
protocol SuggestionsProvider: Sendable {
    /// - Parameters:
    ///   - types: 条目类型，如 `["Movie", "Series"]`。
    ///   - limit: 最多返回的条目数。
    func request(userID: String, types: [String], limit: Int, fields: String) -> APIRequest
}

/// Jellyfin：`/Items/Suggestions?userId=`，类型参数为 `type`。
struct JellyfinSuggestionsProvider: SuggestionsProvider {
    func request(userID: String, types: [String], limit: Int, fields: String) -> APIRequest {
        APIRequest("/Items/Suggestions", query: [
            .init(name: "userId", value: userID),
            .init(name: "type", value: types.joined(separator: ",")),
            .init(name: "limit", value: String(limit)),
            .init(name: "fields", value: fields)
        ])
    }
}

/// Emby：`/Users/{id}/Suggestions`，类型参数为 `IncludeItemTypes`。
struct EmbySuggestionsProvider: SuggestionsProvider {
    func request(userID: String, types: [String], limit: Int, fields: String) -> APIRequest {
        APIRequest("/Users/\(userID)/Suggestions", query: [
            .init(name: "IncludeItemTypes", value: types.joined(separator: ",")),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: fields)
        ])
    }
}

extension MediaServerKind {
    var suggestionsProvider: (any SuggestionsProvider)? {
        switch self {
        case .jellyfin: JellyfinSuggestionsProvider()
        case .emby: EmbySuggestionsProvider()
        case .navidrome: nil
        }
    }
}

extension MediaServerClient {
    /// 服务器推荐的条目（与 Android `MediaRepository.getSuggestions` 相同的接口）；按 id 去重，丢弃无名称的条目。
    /// 服务器未实现该接口时抛出 HTTP 错误，由调用方决定是否回退。
    public func suggestions(types: [String] = ["Movie", "Series"], limit: Int = 15) async throws -> [MediaItem] {
        guard let provider = kind.suggestionsProvider else { return [] }
        let result = try await httpClient.decode(
            QueryResult<BaseItemDTO>.self,
            provider.request(userID: userID, types: types, limit: limit, fields: Self.listFields),
            baseURL: baseURL,
            headers: requestHeaders
        )
        var seen = Set<String>()
        return result.items
            .map { $0.toMediaItem(serverID: serverID) }
            .filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
