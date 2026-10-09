import Foundation
import VelaCore

/// 服务器「为你推荐」的一组（`/Movies/Recommendations`，Jellyfin 与 Emby 相同）：按最近观看 / 喜欢的条目、
/// 导演、演员给出的相似电影。
public struct MediaRecommendation: Sendable, Identifiable {
    /// 服务器的推荐类型，如 `SimilarToRecentlyPlayed`、`HasLikedActor`。
    public var kind: String?
    /// 推荐依据（条目名或人名）。
    public var baselineName: String?
    public var items: [MediaItem]
    public var id: String { "\(kind ?? "")|\(baselineName ?? "")" }

    /// 分组标题（与 Android 版相同的规则，中文）；依据缺失时为 nil。
    public var title: String? {
        guard let baseline = baselineName?.trimmingCharacters(in: .whitespaces), !baseline.isEmpty else { return nil }
        switch kind {
        case "HasDirectorFromRecentlyPlayed", "HasLikedDirector": return "\(baseline) 执导"
        case "HasActorFromRecentlyPlayed", "HasLikedActor": return "\(baseline) 主演"
        case "SimilarToLikedItem": return "因为你喜欢《\(baseline)》"
        case "SimilarToRecentlyPlayed": return "因为你看过《\(baseline)》"
        default: return baseline
        }
    }

    public init(kind: String?, baselineName: String?, items: [MediaItem]) {
        self.kind = kind
        self.baselineName = baselineName
        self.items = items
    }

    /// 同名分组合并（多个电影库各返回一份），条目按 id 去重，空组丢弃。
    public static func merged(_ groups: [MediaRecommendation]) -> [MediaRecommendation] {
        var order: [String] = []
        var byTitle: [String: MediaRecommendation] = [:]
        for group in groups {
            guard let title = group.title, !group.items.isEmpty else { continue }
            if var existing = byTitle[title] {
                let known = Set(existing.items.map(\.id))
                existing.items += group.items.filter { !known.contains($0.id) }
                byTitle[title] = existing
            } else {
                order.append(title)
                byTitle[title] = group
            }
        }
        return order.compactMap { byTitle[$0] }
    }
}

struct RecommendationDTO: Decodable {
    var baselineItemName: String?
    var recommendationType: String?
    var items: [BaseItemDTO]?

    enum CodingKeys: String, CodingKey {
        case baselineItemName = "BaselineItemName"
        case recommendationType = "RecommendationType"
        case items = "Items"
    }
}

extension MediaServerClient {
    /// 电影推荐；`parentID` 为电影库 id（nil 为全部库）。
    public func movieRecommendations(parentID: String?, categoryLimit: Int = 8, itemLimit: Int = 18) async throws -> [MediaRecommendation] {
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: userID),
            .init(name: "CategoryLimit", value: String(categoryLimit)),
            .init(name: "ItemLimit", value: String(itemLimit)),
            .init(name: "Fields", value: Self.listFields)
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        let groups = try await httpClient.decode(
            [RecommendationDTO].self,
            APIRequest("/Movies/Recommendations", query: query),
            baseURL: baseURL,
            headers: requestHeaders
        )
        return groups.map { group in
            MediaRecommendation(
                kind: group.recommendationType,
                baselineName: group.baselineItemName,
                items: (group.items ?? []).map { $0.toMediaItem(serverID: serverID) }
            )
        }
    }
}
