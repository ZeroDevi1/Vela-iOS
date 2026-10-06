import Foundation
import VelaCore

/// 发给服务器的播放能力声明，服务器据此决定直放、转封装（remux）还是转码。
///
/// 面向 AVPlayer：只声明 Apple 原生可解封装的容器；MKV 等交给服务器转封装为 HLS fMP4，
/// 视频流原样复制，不损失 HDR / 杜比视界元数据。KSPlayer 内核直接请求原文件，不依赖此声明。
public struct DeviceProfile: Encodable, Sendable {
    struct DirectPlayProfile: Encodable, Sendable {
        var container: String
        var type: String
        var videoCodec: String?
        var audioCodec: String?

        enum CodingKeys: String, CodingKey {
            case container = "Container", type = "Type", videoCodec = "VideoCodec", audioCodec = "AudioCodec"
        }
    }

    struct TranscodingProfile: Encodable, Sendable {
        var container: String
        var type: String
        var videoCodec: String
        var audioCodec: String
        var context: String
        var `protocol`: String
        var maxAudioChannels: String
        var minSegments: Int
        var breakOnNonKeyFrames: Bool

        enum CodingKeys: String, CodingKey {
            case container = "Container", type = "Type", videoCodec = "VideoCodec", audioCodec = "AudioCodec"
            case context = "Context", `protocol` = "Protocol", maxAudioChannels = "MaxAudioChannels"
            case minSegments = "MinSegments", breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        }
    }

    /// 编解码条件：不满足时服务器不直放 / 不复制视频流，并在转码时按条件缩放（如 `Width` ≤ 上限）。
    struct CodecProfile: Encodable, Sendable {
        struct Condition: Encodable, Sendable {
            var condition: String
            var property: String
            var value: String
            var isRequired: Bool

            enum CodingKeys: String, CodingKey {
                case condition = "Condition", property = "Property", value = "Value", isRequired = "IsRequired"
            }
        }

        var type: String
        var conditions: [Condition]

        enum CodingKeys: String, CodingKey { case type = "Type", conditions = "Conditions" }
    }

    struct SubtitleProfile: Encodable, Sendable {
        var format: String
        var method: String

        enum CodingKeys: String, CodingKey { case format = "Format", method = "Method" }
    }

    var name: String
    var maxStreamingBitrate: Int
    var maxStaticBitrate: Int
    var directPlayProfiles: [DirectPlayProfile]
    var transcodingProfiles: [TranscodingProfile]
    var subtitleProfiles: [SubtitleProfile]
    var codecProfiles: [CodecProfile] = []

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
        case codecProfiles = "CodecProfiles"
        case containerProfiles = "ContainerProfiles"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(maxStreamingBitrate, forKey: .maxStreamingBitrate)
        try c.encode(maxStaticBitrate, forKey: .maxStaticBitrate)
        try c.encode(directPlayProfiles, forKey: .directPlayProfiles)
        try c.encode(transcodingProfiles, forKey: .transcodingProfiles)
        try c.encode(subtitleProfiles, forKey: .subtitleProfiles)
        try c.encode(codecProfiles, forKey: .codecProfiles)
        try c.encode([String](), forKey: .containerProfiles)
    }

    /// 发给服务器的能力声明对应哪个内核。
    public enum Kind: Sendable {
        /// 系统内核：只直放 Apple 原生容器，其余由服务器转封装为 HLS。
        case avFoundation
        /// KSPlayer：FFmpeg 解封装，MKV 等直接播放原文件，内嵌字幕由播放器从视频流读取。
        case ksPlayer
    }

    public static func make(_ kind: Kind, _ caps: PlaybackCapabilities) -> DeviceProfile {
        switch kind {
        case .avFoundation: avFoundation(caps)
        case .ksPlayer: ksPlayer(caps)
        }
    }

    /// KSPlayer 能力，容器与编码列表与 Android 版（MPV / ExoPlayer）一致：常见容器都直放原文件，
    /// 文本字幕声明 Embed（播放器边播边从视频流读取，不让服务器读完整个文件去提取）与 External（外挂字幕文件）。
    /// 图形字幕暂只声明 Encode（由服务器烧录）：Vela 的字幕层还不绘制 KSPlayer 解出的图形字幕。
    public static func ksPlayer(_ caps: PlaybackCapabilities) -> DeviceProfile {
        var profile = avFoundation(caps)
        profile.name = "Vela KSPlayer"
        profile.directPlayProfiles = [
            DirectPlayProfile(
                container: "mp4,m4v,mov,mkv,webm,ts,m2ts,avi",
                type: "Video",
                videoCodec: "h264,hevc,vp9,av1,mpeg4,mpeg2video,vp8",
                audioCodec: "aac,mp3,ac3,eac3,dts,flac,opus,vorbis,truehd,pcm,alac"
            )
        ]
        let textFormats = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "ttml", "sub", "smi", "microdvd"]
        profile.subtitleProfiles = textFormats.flatMap {
            [SubtitleProfile(format: $0, method: "Embed"), SubtitleProfile(format: $0, method: "External")]
        } + ["pgs", "pgssub", "dvdsub", "vobsub"].map { SubtitleProfile(format: $0, method: "Encode") }
        return profile
    }

    /// AVPlayer 原生能力。
    public static func avFoundation(_ caps: PlaybackCapabilities) -> DeviceProfile {
        var videoCodecs = ["h264"]
        if caps.supportsHEVC { videoCodecs.append("hevc") }
        if caps.supportsAV1 { videoCodecs.append("av1") }
        let video = videoCodecs.joined(separator: ",")
        let audio = caps.supportsEAC3 ? "aac,ac3,eac3,alac,flac,mp3,opus" : "aac,ac3,alac,flac,mp3,opus"

        return DeviceProfile(
            name: "Vela AVFoundation",
            maxStreamingBitrate: caps.maxStreamingBitrate,
            maxStaticBitrate: caps.maxStreamingBitrate,
            directPlayProfiles: [
                DirectPlayProfile(container: "mp4,m4v,mov", type: "Video", videoCodec: video, audioCodec: audio)
            ],
            transcodingProfiles: [
                // fMP4 分片才能承载 HEVC / 杜比视界；TS 分片在 AVPlayer 上不支持 HEVC 的 DV。
                TranscodingProfile(
                    container: "mp4",
                    type: "Video",
                    videoCodec: caps.supportsHEVC ? "hevc,h264" : "h264",
                    audioCodec: caps.supportsEAC3 ? "aac,ac3,eac3,alac,flac" : "aac,ac3,alac,flac",
                    context: "Streaming",
                    protocol: "hls",
                    maxAudioChannels: String(caps.maxAudioChannels),
                    minSegments: 2,
                    breakOnNonKeyFrames: true
                )
            ],
            // 文本字幕全部声明为 External：由客户端拉取 WebVTT 自行渲染，直放与转码通用，且不会因字幕触发转码。
            // 图形字幕（PGS / VobSub）不声明，用户选择时服务器会烧录进画面。
            subtitleProfiles: ["vtt", "webvtt", "srt", "subrip", "ass", "ssa", "mov_text", "ttml", "sub"].map {
                SubtitleProfile(format: $0, method: "External")
            },
            codecProfiles: caps.maxVideoWidth.map { width in
                [CodecProfile(type: "Video", conditions: [
                    CodecProfile.Condition(condition: "LessThanEqual", property: "Width", value: String(width), isRequired: true)
                ])]
            } ?? []
        )
    }
}
