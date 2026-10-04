import Foundation
import VelaCore
import VelaNetwork

/// 片头 / 片尾区段来源：Jellyfin 优先 MediaSegments（10.10+），其余回退到章节标记（Emby `IntroStart` 等）。
public struct PlaybackSegmentProvider: Sendable {
    public init() {}

    /// 拿不到任何区段时返回空数组，不视为错误：片段是锦上添花，不能阻断播放。
    public func segments(for item: MediaItem, client: MediaServerClient) async -> [PlaybackSegment] {
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
