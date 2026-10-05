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

    /// 服务器在转码地址的 `TranscodeReasons` 参数中给出的原因（例如 `ContainerNotSupported`）；直放时为空。
    public var transcodeReasons: [String] {
        guard method == .transcode,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name.caseInsensitiveCompare("TranscodeReasons") == .orderedSame })?.value
        else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
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

    /// 原文件静态串流（不经转码），供 MPV 内核直放。STRM 原始地址已是直放时原样返回。
    public func originalFileStream(for stream: ResolvedStream, item: MediaItem, client: MediaServerClient) throws -> ResolvedStream {
        guard stream.method == .transcode else { return stream }
        let source = stream.mediaSource
        let url = try client.directStreamURL(
            itemID: item.id,
            mediaSourceID: source.id,
            playSessionID: stream.playSessionID,
            container: source.container?.split(separator: ",").first.map(String.init)
        )
        return ResolvedStream(url: url, method: .directPlay, mediaSource: source, playSessionID: stream.playSessionID,
                              audioStreamIndex: stream.audioStreamIndex, burnedSubtitleIndex: nil)
    }

    /// 下载用的流。
    public struct DownloadSource: Sendable {
        public var url: URL
        /// true：服务器转码的 HLS（用 AVAssetDownloadTask）；false：原文件（用普通下载任务）。
        public var isHLS: Bool
        /// 原文件的扩展名（容器），用于保存文件名。
        public var fileExtension: String
        public var playSessionID: String?
    }

    /// 选择下载流：原画下载原文件；限定码率时，原文件码率不超过上限且可直放则仍下载原文件，否则下载转码 HLS。
    public func resolveDownload(
        item: MediaItem,
        client: MediaServerClient,
        quality: DownloadQuality,
        capabilities: PlaybackCapabilities
    ) async throws -> DownloadSource {
        var caps = capabilities
        // 下载内容要在系统内核离线播放：不声明杜比视界 / AV1，避免得到需要特殊解码的流。
        caps.supportsDolbyVision = false
        caps.supportsAV1 = false
        if let limit = quality.maxBitrate { caps.maxStreamingBitrate = limit }
        let info = try await client.playbackInfo(itemID: item.id, capabilities: caps)
        guard let source = info.mediaSources.first else { throw PlaybackResolveError.noMediaSource }
        let container = source.container?.split(separator: ",").first.map(String.init) ?? "mkv"

        let withinLimit = quality.maxBitrate.map { (source.bitrate ?? .max) <= $0 } ?? true
        if quality == .original || (source.supportsDirectPlay && withinLimit) {
            let url = try client.directStreamURL(itemID: item.id, mediaSourceID: source.id, playSessionID: info.playSessionID, container: container)
            return DownloadSource(url: url, isHLS: false, fileExtension: container, playSessionID: nil)
        }
        guard let relative = source.transcodingURL else { throw PlaybackResolveError.unsupported }
        return DownloadSource(
            url: try client.absoluteURL(forServerRelative: relative),
            isHLS: true,
            fileExtension: "movpkg",
            playSessionID: info.playSessionID
        )
    }

    /// 拖动预览用的独立低码率流（主播放为服务器转码 / 转封装 HLS 时使用）。
    ///
    /// 单独请求 PlaybackInfo 得到新的 PlaySessionId，服务器为其启动独立的转码进程，
    /// 预览播放器的随机 seek 不会打断主播放的转码会话。用 H.264 / SDR / 2 声道 / 低码率声明，
    /// 让服务器输出小分片以加快 seek 后的首帧。调用方负责在结束时停止该会话的转码。
    public func resolvePreview(
        item: MediaItem,
        client: MediaServerClient,
        mediaSourceID: String?
    ) async throws -> ResolvedStream {
        let capabilities = PlaybackCapabilities(
            supportsAV1: false,
            supportsHEVC: false,
            supportsDolbyVision: false,
            supportsHDR10: false,
            maxAudioChannels: 2,
            maxStreamingBitrate: Self.previewBitrate
        )
        let info = try await client.playbackInfo(
            itemID: item.id,
            mediaSourceID: mediaSourceID,
            capabilities: capabilities
        )
        let source = info.mediaSources.first { $0.id == mediaSourceID } ?? info.mediaSources.first
        guard let source else { throw PlaybackResolveError.noMediaSource }
        if let relative = source.transcodingURL {
            let url = try client.absoluteURL(forServerRelative: relative)
            return ResolvedStream(url: url, method: .transcode, mediaSource: source, playSessionID: info.playSessionID)
        }
        if source.supportsDirectPlay {
            let url = try client.directStreamURL(
                itemID: item.id,
                mediaSourceID: source.id,
                playSessionID: info.playSessionID,
                container: source.container?.split(separator: ",").first.map(String.init)
            )
            return ResolvedStream(url: url, method: .directPlay, mediaSource: source, playSessionID: info.playSessionID)
        }
        throw PlaybackResolveError.unsupported
    }

    /// 预览流码率上限（bit/s）：约 480p，足够 480 像素宽的缩略图。
    static let previewBitrate = 1_200_000
}
