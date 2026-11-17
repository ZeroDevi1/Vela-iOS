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
    public var itemID: String?
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
    /// `VideoFile` / `Iso` / `Dvd` / `BluRay`（原盘文件夹或镜像）。
    public var videoType: String?
    /// 镜像类型：`Dvd` / `BluRay`；非镜像为 nil。
    public var isoType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemID = "ItemId"
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
        case videoType = "VideoType"
        case isoType = "IsoType"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        itemID = try? c.decode(String.self, forKey: .itemID)
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
        videoType = try c.decodeIfPresent(String.self, forKey: .videoType)
        isoType = try c.decodeIfPresent(String.self, forKey: .isoType)
    }

    /// 蓝光 / DVD 原盘（BDMV、VIDEO_TS 文件夹或 ISO 镜像）。播放器读不了原盘结构（KSPlayer GPL 版不含蓝光读取，
    /// iOS 的 FFmpegKit 也没有 libbluray），只能由服务器读取后转封装 / 转码。服务器字段缺失时按容器与路径判断。
    public var isDiscImage: Bool {
        if let videoType, ["iso", "dvd", "bluray"].contains(videoType.lowercased()) { return true }
        if isoType != nil { return true }
        let containers = (container ?? "").lowercased().split(separator: ",").map(String.init)
        if containers.contains(where: { ["iso", "bluray", "dvd", "bdmv"].contains($0) }) { return true }
        let path = (path ?? "").lowercased().replacingOccurrences(of: "\\", with: "/")
        return path.hasSuffix(".iso") || path.hasSuffix("/bdmv") || path.contains("/bdmv/") || path.hasSuffix("/video_ts")
            || path.contains("/video_ts/")
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
    /// Emby / 旧版 Jellyfin：`SDR` / `HDR`，不区分具体格式。
    public var videoRange: String?
    /// Emby：`Hdr10` / `Hdr10Plus` / `DolbyVision` / `HyperLogGamma` 等（Jellyfin 无此字段）。
    public var extendedVideoType: String?
    /// 传递函数：`smpte2084`（PQ，HDR10 / 杜比视界）、`arib-std-b67`（HLG）、`bt709`（SDR）。
    public var colorTransfer: String?
    /// Jellyfin：杜比视界 Profile（5 / 7 / 8 …）。
    public var dvProfile: Int?
    /// Emby：杜比视界细分类型，如 `DoviProfile81`（Profile 8.1）、`DoviProfile76`、`DoviProfile50`。
    public var extendedVideoSubType: String?
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
        case videoRange = "VideoRange"
        case extendedVideoType = "ExtendedVideoType"
        case colorTransfer = "ColorTransfer"
        case dvProfile = "DvProfile"
        case extendedVideoSubType = "ExtendedVideoSubType"
        case channels = "Channels"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
        case isForced = "IsForced"
        case isTextSubtitleStream = "IsTextSubtitleStream"
    }

    /// 图形字幕编码；服务器未给 `IsTextSubtitleStream` 时按编码判断。
    private static let imageSubtitleCodecs: Set<String> = ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub"]

    /// 杜比视界 Profile；不是杜比视界或服务器未给出时为 nil。
    public var dolbyVisionProfile: Int? {
        if let dvProfile, dvProfile > 0 { return dvProfile }
        guard let subType = extendedVideoSubType?.lowercased(), subType.hasPrefix("doviprofile") else { return nil }
        let digits = subType.dropFirst("doviprofile".count).prefix { $0.isNumber }
        // 末位是兼容 ID（81 → Profile 8 / 兼容 1）；Profile 10 写作 101 / 102 等三位数。
        guard digits.count >= 2 else { return Int(digits) }
        return Int(digits.dropLast())
    }

    /// 音轨是否为杜比全景声（服务器在 Profile / 标题中注明，如 `Dolby Digital Plus + Dolby Atmos`）。
    public var isDolbyAtmos: Bool {
        [profile, displayTitle, title].contains { $0?.localizedCaseInsensitiveContains("atmos") == true }
    }

    public var isTextSubtitle: Bool {
        if let isTextSubtitleStream { return isTextSubtitleStream }
        return !Self.imageSubtitleCodecs.contains(codec?.lowercased() ?? "")
    }

    /// PGS 位图随原文件读取；外挂 PGS 仍需服务器处理。
    public var isEmbeddedPGS: Bool {
        isExternal != true && ["pgs", "pgssub", "hdmv_pgs_subtitle"].contains(codec?.lowercased() ?? "")
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
