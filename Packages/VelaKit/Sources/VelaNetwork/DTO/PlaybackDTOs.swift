import Foundation
import VelaCore

struct PlaybackInfoBody: Encodable, Sendable {
    var userID: String
    var maxStreamingBitrate: Int
    var startTimeTicks: Int64
    var mediaSourceID: String?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var deviceProfile: DeviceProfile

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case startTimeTicks = "StartTimeTicks"
        case mediaSourceID = "MediaSourceId"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case deviceProfile = "DeviceProfile"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case autoOpenLiveStream = "AutoOpenLiveStream"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(maxStreamingBitrate, forKey: .maxStreamingBitrate)
        try c.encode(startTimeTicks, forKey: .startTimeTicks)
        try c.encodeIfPresent(mediaSourceID, forKey: .mediaSourceID)
        try c.encodeIfPresent(audioStreamIndex, forKey: .audioStreamIndex)
        // 默认传 -1（不选字幕）：否则服务器可能按用户偏好选中图形字幕并强制烧录转码。
        try c.encode(subtitleStreamIndex ?? -1, forKey: .subtitleStreamIndex)
        try c.encode(deviceProfile, forKey: .deviceProfile)
        try c.encode(true, forKey: .enableDirectPlay)
        try c.encode(true, forKey: .enableDirectStream)
        try c.encode(true, forKey: .enableTranscoding)
        // 允许视频流复制：HEVC / DV 只需转封装成 HLS，不触发服务器重编码。
        try c.encode(true, forKey: .allowVideoStreamCopy)
        try c.encode(true, forKey: .allowAudioStreamCopy)
        try c.encode(true, forKey: .autoOpenLiveStream)
    }
}

public struct PlaybackInfoResponse: Decodable, Sendable {
    public var mediaSources: [MediaSourceInfo]
    public var playSessionID: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
    }
}

public struct MediaSourceInfo: Decodable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var path: String?
    /// `File` / `Http` 等；STRM 条目通常是 `Http`。
    public var `protocol`: String?
    public var container: String?
    public var size: Int64?
    public var bitrate: Int?
    public var supportsDirectPlay: Bool
    public var supportsDirectStream: Bool
    public var supportsTranscoding: Bool
    /// 服务器决定转码 / 转封装时给出的相对 URL（已含 PlaySessionId 等参数）。
    public var transcodingURL: String?
    public var isRemote: Bool?
    public var runTimeTicks: Int64?
    public var mediaStreams: [MediaStreamInfo]
    /// 服务器按用户语言偏好选出的默认音轨 / 字幕（`MediaStream.Index`）；字幕为 nil 或 -1 表示默认不显示。
    public var defaultAudioStreamIndex: Int?
    public var defaultSubtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case `protocol` = "Protocol"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingURL = "TranscodingUrl"
        case isRemote = "IsRemote"
        case mediaStreams = "MediaStreams"
        case runTimeTicks = "RunTimeTicks"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        supportsDirectPlay = try c.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay) ?? false
        supportsDirectStream = try c.decodeIfPresent(Bool.self, forKey: .supportsDirectStream) ?? false
        supportsTranscoding = try c.decodeIfPresent(Bool.self, forKey: .supportsTranscoding) ?? false
        transcodingURL = try c.decodeIfPresent(String.self, forKey: .transcodingURL)
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote)
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        mediaStreams = try c.decodeIfPresent([MediaStreamInfo].self, forKey: .mediaStreams) ?? []
        defaultAudioStreamIndex = try c.decodeIfPresent(Int.self, forKey: .defaultAudioStreamIndex)
        defaultSubtitleStreamIndex = try c.decodeIfPresent(Int.self, forKey: .defaultSubtitleStreamIndex)
    }

    public var videoStream: MediaStreamInfo? { mediaStreams.first { $0.type == "Video" } }
    public var audioStreams: [MediaStreamInfo] { mediaStreams.filter { $0.type == "Audio" } }
    public var subtitleStreams: [MediaStreamInfo] { mediaStreams.filter { $0.type == "Subtitle" } }
}

public struct MediaStreamInfo: Decodable, Sendable, Hashable {
    public var index: Int
    /// `Video` / `Audio` / `Subtitle`。
    public var type: String
    public var codec: String?
    /// 封装层的编码标签，例如 HEVC 的 `hvc1` / `hev1`。AVFoundation 只能解码 `hvc1` / `dvh1` 标签的 HEVC。
    public var codecTag: String?
    public var profile: String?
    public var bitDepth: Int?
    public var level: Double?
    public var title: String?
    public var bitRate: Int?
    public var realFrameRate: Double?
    public var aspectRatio: String?
    public var pixelFormat: String?
    public var isInterlaced: Bool?
    public var channelLayout: String?
    public var sampleRate: Int?
    public var language: String?
    public var displayTitle: String?
    public var width: Int?
    public var height: Int?
    /// `SDR` / `HDR10` / `HDR10Plus` / `DOVI` / `DOVIWithHDR10` / `HLG` 等（Jellyfin 10.9+）。
    public var videoRangeType: String?
    public var channels: Int?
    public var isDefault: Bool?
    public var isExternal: Bool?
    public var isForced: Bool?
    /// 服务器判定的文本字幕（可转 WebVTT）；图形字幕（PGS / VobSub）只能烧录。
    public var isTextSubtitleStream: Bool?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case codecTag = "CodecTag"
        case profile = "Profile"
        case bitDepth = "BitDepth"
        case level = "Level"
        case title = "Title"
        case bitRate = "BitRate"
        case realFrameRate = "RealFrameRate"
        case aspectRatio = "AspectRatio"
        case pixelFormat = "PixelFormat"
        case isInterlaced = "IsInterlaced"
        case channelLayout = "ChannelLayout"
        case sampleRate = "SampleRate"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case width = "Width"
        case height = "Height"
        case videoRangeType = "VideoRangeType"
        case channels = "Channels"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
        case isForced = "IsForced"
        case isTextSubtitleStream = "IsTextSubtitleStream"
    }

    /// 图形字幕编码；服务器未给 `IsTextSubtitleStream` 时按编码判断。
    private static let imageSubtitleCodecs: Set<String> = ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub"]

    public var isTextSubtitle: Bool {
        if let isTextSubtitleStream { return isTextSubtitleStream }
        return !Self.imageSubtitleCodecs.contains(codec?.lowercased() ?? "")
    }
}

/// 一次播放上报所需的状态快照。
public struct PlaybackReportState: Sendable, Equatable {
    public var itemID: String
    public var mediaSourceID: String
    public var playSessionID: String?
    /// 当前位置，单位秒。
    public var position: TimeInterval
    public var isPaused: Bool
    /// `DirectPlay` / `DirectStream` / `Transcode`。
    public var playMethod: String
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?

    public init(
        itemID: String,
        mediaSourceID: String,
        playSessionID: String?,
        position: TimeInterval,
        isPaused: Bool,
        playMethod: String,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) {
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.position = position
        self.isPaused = isPaused
        self.playMethod = playMethod
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
    }
}

extension MediaStreamInfo {
    /// 音轨 / 字幕的展示信息（中文语言名、采样率、码率、标记）；视频流返回 nil。
    public var trackLabel: TrackLabel? {
        let kind: TrackAttributes.Kind
        switch type {
        case "Audio": kind = .audio
        case "Subtitle": kind = .subtitle
        default: return nil
        }
        return TrackLabelFormatter.label(for: TrackAttributes(
            kind: kind,
            index: index,
            language: language,
            title: title,
            displayTitle: displayTitle,
            codec: codec,
            channels: channels,
            channelLayout: channelLayout,
            sampleRate: sampleRate,
            bitRate: bitRate,
            isDefault: isDefault ?? false,
            isForced: isForced ?? false,
            isExternal: isExternal ?? false
        ))
    }
}
