import Foundation
import VelaCore
import VelaNetwork

/// 片头 / 片尾区段来源：Jellyfin 优先 MediaSegments（10.10+），其余回退到章节标记（Emby `IntroStart` 等）。
public struct PlaybackSegmentProvider: Sendable {
    public init() {}

    /// 拿不到任何区段时返回空数组，不视为错误：片段是锦上添花，不能阻断播放。
    /// 单集再用社区数据库（TheIntroDB / IntroDB）补充服务器没有的区段类型。
    public func segments(for item: MediaItem, client: MediaServerClient) async -> [PlaybackSegment] {
        let server = await serverSegments(for: item, client: client)
        guard item.kind == .episode, let season = item.parentIndexNumber, let episode = item.indexNumber else { return server }
        // 社区数据库按剧集的外部 id 查询；剧集信息取不到时退回单集自己的 id。
        let series = try? await item.seriesID.asyncMap { try await client.item(id: $0) }
        let tmdb = series?.providerIDs.value(forProvider: "Tmdb") ?? item.providerIDs.value(forProvider: "Tmdb")
        let imdb = series?.providerIDs.value(forProvider: "Imdb") ?? item.providerIDs.value(forProvider: "Imdb")
        guard tmdb != nil || imdb != nil else { return server }
        let community = await CommunitySegmentsClient.shared.segments(tmdbID: tmdb, imdbID: imdb, season: season, episode: episode)
        if !community.isEmpty {
            Log.player.info("社区片段：\(community.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
        }
        return PlaybackSegment.merging(server: server, community: community)
    }

    private func serverSegments(for item: MediaItem, client: MediaServerClient) async -> [PlaybackSegment] {
        if client.kind == .jellyfin {
            do {
                let segments = try await client.mediaSegments(itemID: item.id)
                if !segments.isEmpty { return segments.sorted { $0.start < $1.start } }
            } catch {
                Log.player.info("MediaSegments 不可用，回退章节标记：\(error.localizedDescription, privacy: .public)")
            }
        }
        return MediaChapter.segments(from: item.chapters)
    }
}

private extension [String: String] {
    /// 外部 id（键名大小写不敏感，Emby 与 Jellyfin 写法不同）；空值视为没有。
    func value(forProvider name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
