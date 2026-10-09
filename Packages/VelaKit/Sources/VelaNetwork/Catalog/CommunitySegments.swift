import Foundation
import VelaCore

/// 社区片头 / 片尾标记（与 Android 版相同的两个来源）：
/// - TheIntroDB（`api.theintrodb.org`，按 TMDB 剧集 id + 季 + 集）：片头、回顾、片尾、预告
/// - IntroDB（`api.introdb.app`，按 IMDb 剧集 id + 季 + 集）：只有片头，TheIntroDB 没有片头时补充
///
/// 只用于单集，且只补充服务器（媒体片段 / 章节）没有给出的类型。请求超时很短：拿不到时不影响播放。
public actor CommunitySegmentsClient {
    public static let shared = CommunitySegmentsClient()

    private let session: URLSession
    /// 6 小时内的查询结果（含「没有数据」）。
    private var cache: [String: (segments: [PlaybackSegment], at: Date)] = [:]
    private static let cacheLifetime: TimeInterval = 6 * 3600

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        session = URLSession(configuration: configuration)
    }

    /// - Parameters:
    ///   - tmdbID / imdbID: 剧集（不是单集）的外部 id；单集自己的 id 也可作为退路。
    public func segments(tmdbID: String?, imdbID: String?, season: Int, episode: Int) async -> [PlaybackSegment] {
        let key = "\(tmdbID ?? "-")|\(imdbID ?? "-")|\(season)|\(episode)"
        if let cached = cache[key], Date.now.timeIntervalSince(cached.at) < Self.cacheLifetime { return cached.segments }
        var result: [PlaybackSegment] = []
        if let tmdbID {
            result = (try? await theIntroDB(tmdbID: tmdbID, season: season, episode: episode)) ?? []
        }
        if !result.contains(where: { $0.kind == .intro }), let imdbID,
           let intro = try? await introDB(imdbID: imdbID, season: season, episode: episode) {
            result.append(intro)
        }
        result.sort { $0.start < $1.start }
        cache[key] = (result, .now)
        return result
    }

    private func theIntroDB(tmdbID: String, season: Int, episode: Int) async throws -> [PlaybackSegment] {
        var components = URLComponents(string: "https://api.theintrodb.org/v2/media")!
        components.queryItems = [.init(name: "tmdb_id", value: tmdbID), .init(name: "season", value: String(season)), .init(name: "episode", value: String(episode))]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try Self.parseTheIntroDB(data)
    }

    private func introDB(imdbID: String, season: Int, episode: Int) async throws -> PlaybackSegment? {
        var components = URLComponents(string: "https://api.introdb.app/segments")!
        components.queryItems = [
            .init(name: "imdb_id", value: imdbID), .init(name: "season", value: String(season)),
            .init(name: "episode", value: String(episode)), .init(name: "segment_type", value: "intro"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try Self.parseIntroDB(data)
    }

    private struct Window: Decodable {
        var startMs: Int64?
        var endMs: Int64?
        enum CodingKeys: String, CodingKey { case startMs = "start_ms", endMs = "end_ms" }

        /// 开始缺省为 0；结束缺省表示到片尾（片尾标记常见）；结束不晚于开始的视为无效。
        func segment(_ kind: PlaybackSegment.Kind) -> PlaybackSegment? {
            guard startMs != nil || endMs != nil else { return nil }
            let start = Double(startMs ?? 0) / 1000
            let end = endMs.map { Double($0) / 1000 }
            if let end, end <= start { return nil }
            return PlaybackSegment(kind: kind, start: start, end: end)
        }
    }

    static func parseTheIntroDB(_ data: Data) throws -> [PlaybackSegment] {
        struct Response: Decodable {
            var intro: [Window]?
            var recap: [Window]?
            var credits: [Window]?
            var preview: [Window]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return [
            response.intro?.first?.segment(.intro),
            response.recap?.first?.segment(.recap),
            response.credits?.first?.segment(.outro),
            response.preview?.first?.segment(.preview),
        ].compactMap { $0 }
    }

    static func parseIntroDB(_ data: Data) throws -> PlaybackSegment? {
        struct Response: Decodable { var intro: Window? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        // IntroDB 的片头必须有开始与结束。
        guard let window = response.intro, window.startMs != nil, window.endMs != nil else { return nil }
        return window.segment(.intro)
    }
}
