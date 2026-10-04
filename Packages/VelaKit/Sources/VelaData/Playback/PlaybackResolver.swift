import Foundation
import VelaCore
import VelaNetwork

/// 解析后的可播放流。
public struct ResolvedStream: Sendable {
    public enum Method: String, Sendable {
        /// 原文件直放（含 STRM 原始地址）。
        case directPlay
        /// 服务器转封装或转码后的 HLS。
        case transcode
    }

    public var url: URL
    public var method: Method
    public var mediaSource: MediaSourceInfo
    public var playSessionID: String?
    /// 请求时指定的音轨；nil 表示服务器默认。
    public var audioStreamIndex: Int?
    /// 烧录进画面的图形字幕；nil 表示未烧录（文本字幕由客户端渲染，不经过这里）。
    public var burnedSubtitleIndex: Int?

    /// 上报给服务器的 PlayMethod。
    public var reportPlayMethod: String { method == .directPlay ? "DirectPlay" : "Transcode" }
}

public enum PlaybackResolveError: LocalizedError {
    case noMediaSource
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .noMediaSource: "服务器没有返回可用的媒体源"
        case .unsupported: "当前播放内核无法播放该媒体源，且服务器未提供转码"
        }
    }
}

/// 根据 PlaybackInfo 选择播放方式：能直放就直放（画质与 HDR 元数据完整保留），否则使用服务器给出的转码地址。
public struct PlaybackResolver: Sendable {
    public init() {}

    public func resolve(
        item: MediaItem,
        server: SavedServer,
        client: MediaServerClient,
        capabilities: PlaybackCapabilities,
        mediaSourceID: String? = nil,
        startTime: TimeInterval = 0,
        audioStreamIndex: Int? = nil,
        burnSubtitleIndex: Int? = nil
    ) async throws -> ResolvedStream {
        let info = try await client.playbackInfo(
            itemID: item.id,
            mediaSourceID: mediaSourceID,
            startTicks: Ticks.ticks(startTime),
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: burnSubtitleIndex,
            capabilities: capabilities
        )
        let source = info.mediaSources.first { $0.id == mediaSourceID } ?? info.mediaSources.first
        guard let source else { throw PlaybackResolveError.noMediaSource }

        // STRM：Path 是 http(s) 时按用户偏好直接播放原始地址，不经服务器中转。
        if server.preferStrmOriginalPath,
           source.protocol == "Http",
           let path = source.path,
           let url = URL(string: path),
           url.scheme == "http" || url.scheme == "https" {
            return ResolvedStream(url: url, method: .directPlay, mediaSource: source, playSessionID: info.playSessionID,
                                  audioStreamIndex: audioStreamIndex, burnedSubtitleIndex: nil)
        }

        // 需要烧录字幕时服务器不会给出直放；其余情况能直放就直放。
        if source.supportsDirectPlay, burnSubtitleIndex == nil {
            let url = try client.directStreamURL(
                itemID: item.id,
                mediaSourceID: source.id,
                playSessionID: info.playSessionID,
                container: source.container?.split(separator: ",").first.map(String.init)
            )
            return ResolvedStream(url: url, method: .directPlay, mediaSource: source, playSessionID: info.playSessionID,
                                  audioStreamIndex: audioStreamIndex, burnedSubtitleIndex: nil)
        }

        if let relative = source.transcodingURL {
            let url = try client.absoluteURL(forServerRelative: relative)
            return ResolvedStream(url: url, method: .transcode, mediaSource: source, playSessionID: info.playSessionID,
                                  audioStreamIndex: audioStreamIndex, burnedSubtitleIndex: burnSubtitleIndex)
        }
        throw PlaybackResolveError.unsupported
    }
}
