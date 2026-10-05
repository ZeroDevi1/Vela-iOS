import Foundation

/// 把同一部电影的多个库条目（不同版本的文件被刮削成独立条目）合并成一项显示。
///
/// 只按 provider id（TMDB 优先，其次 IMDb）精确匹配，不按标题模糊匹配；没有 provider id 的条目原样保留。
/// 只合并电影：剧集合并会打乱季 / 集结构。合并后保留首次出现的条目（保持排序），其余条目 id 记入 `mergedItemIDs`。
public enum MediaItemMerger {
    public static func merge(_ items: [MediaItem]) -> [MediaItem] {
        var result: [MediaItem] = []
        var indexByKey: [String: Int] = [:]
        for item in items {
            guard let key = mergeKey(for: item) else {
                result.append(item)
                continue
            }
            if let index = indexByKey[key] {
                guard result[index].id != item.id, !result[index].mergedItemIDs.contains(item.id) else { continue }
                result[index].mergedItemIDs.append(item.id)
                // 合并后的观看状态：任一版本看过即视为看过。
                result[index].isPlayed = result[index].isPlayed || item.isPlayed
            } else {
                indexByKey[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    static func mergeKey(for item: MediaItem) -> String? {
        guard item.kind == .movie else { return nil }
        if let tmdb = item.providerIDs["tmdb"], !tmdb.isEmpty { return "\(item.serverID)|tmdb|\(tmdb)" }
        if let imdb = item.providerIDs["imdb"], !imdb.isEmpty { return "\(item.serverID)|imdb|\(imdb)" }
        return nil
    }
}
