import Foundation
import VelaCore

/// 发给服务器的播放能力声明，服务器据此决定直放、转封装（remux）还是转码。
///
/// 当前面向 AVPlayer：只声明 Apple 原生可解封装的容器；MKV 等交给服务器转封装为 HLS fMP4，
/// 视频流原样复制，不损失 HDR / 杜比视界元数据。接入 MPV / KSPlayer 内核后，由内核提供各自的 profile。
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
        try c.encode([String](), forKey: .codecProfiles)
        try c.encode([String](), forKey: .containerProfiles)
    }

    /// AVPlayer 原生能力。
    public static func avFoundation(_ caps: PlaybackCapabilities) -> DeviceProfile {
        var videoCodecs = ["h264"]
        if caps.supportsHEVC { videoCodecs.append("hevc") }
        if caps.supportsAV1 { videoCodecs.append("av1") }
        let video = videoCodecs.joined(separator: ",")
        let audio = "aac,ac3,eac3,alac,flac,mp3,opus"

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
                    audioCodec: "aac,ac3,eac3,alac,flac",
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
            }
        )
    }
}
