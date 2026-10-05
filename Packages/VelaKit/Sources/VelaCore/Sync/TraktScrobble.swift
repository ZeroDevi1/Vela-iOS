import Foundation

/// Trakt scrobble 的识别信息：只用 provider id，不按标题匹配；没有可用 id 的条目不同步。
public enum TraktScrobble {
    public enum Action: String, Sendable {
        case start, pause, stop
    }

    /// 生成 scrobble 请求体（不含 progress）。电影用 TMDB / IMDb；单集用单集自身的 TVDB / TMDB / IMDb。
    public static func body(for item: MediaItem) -> [String: [String: [String: String]]]? {
        let ids = item.providerIDs
        func pick(_ keys: [String]) -> [String: String] {
            var result: [String: String] = [:]
            for key in keys { if let value = ids[key], !value.isEmpty { result[key] = value } }
            return result
        }
        switch item.kind {
        case .movie:
            let selected = pick(["tmdb", "imdb"])
            return selected.isEmpty ? nil : ["movie": ["ids": selected]]
        case .episode:
            let selected = pick(["tvdb", "tmdb", "imdb"])
            return selected.isEmpty ? nil : ["episode": ["ids": selected]]
        default:
            return nil
        }
    }

    /// 播放进度百分比（0–100）；Trakt 在 stop 时进度 ≥ 80% 记为已看。
    public static func progress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(100, max(0, position / duration * 100))
    }
}
