import Foundation
import VelaCore

/// 播放前的轨道 / 版本挑选规则（纯逻辑，便于单测）。
public enum MediaSelection {
    /// 语言代码归一：服务器可能给出 ISO 639-2 的 B / T 两种写法或 639-1 两字母码。
    public static func normalizedLanguage(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        switch code {
        case "zho", "chi", "zh", "chs", "cht", "cmn", "zh-cn", "zh-tw", "zh-hans", "zh-hant": return "chi"
        case "yue", "zh-hk": return "yue"
        case "en", "eng": return "eng"
        case "ja", "jpn": return "jpn"
        case "ko", "kor": return "kor"
        case "fr", "fre", "fra": return "fre"
        case "de", "ger", "deu": return "ger"
        case "es", "spa": return "spa"
        case "ru", "rus": return "rus"
        default: return code
        }
    }

    /// 第一条语言匹配的轨道；`language` 为空时返回 nil（交给服务器默认）。
    public static func firstStream(matching language: String?, in streams: [MediaStreamInfo]) -> MediaStreamInfo? {
        guard let target = normalizedLanguage(language) else { return nil }
        return streams.first { normalizedLanguage($0.language) == target }
    }

    /// 多版本条目未指定版本时按「视频首选版本」挑选：画质按分辨率（像素数）再按码率比较。
    public static func preferredSource(_ sources: [MediaSourceInfo], by preference: MediaVersionPreference) -> MediaSourceInfo? {
        guard sources.count > 1 else { return sources.first }
        func pixels(_ source: MediaSourceInfo) -> Int { (source.videoStream?.width ?? 0) * (source.videoStream?.height ?? 0) }
        func bitrate(_ source: MediaSourceInfo) -> Int { source.bitrate ?? 0 }
        switch preference {
        case .serverDefault:
            return sources.first
        case .highestQuality:
            return sources.max { (pixels($0), bitrate($0)) < (pixels($1), bitrate($1)) }
        case .highestBitrate:
            return sources.max { (bitrate($0), pixels($0)) < (bitrate($1), pixels($1)) }
        case .bestDynamicRange:
            return sources.max {
                (rangeRank($0.videoStream?.videoRangeType), pixels($0), bitrate($0))
                    < (rangeRank($1.videoStream?.videoRangeType), pixels($1), bitrate($1))
            }
        case .uhd4K, .fullHD1080, .hd720:
            // 宽度留 10% 余量：2.39:1 电影的 1080p 版本宽 1920，部分编码为 1998 / 2048。
            let limit = Double(preference.targetWidth ?? 0) * 1.1
            let fitting = sources.filter { Double($0.videoStream?.width ?? 0) <= limit }
            if let best = fitting.max(by: { (pixels($0), bitrate($0)) < (pixels($1), bitrate($1)) }) { return best }
            return sources.min { (pixels($0), bitrate($0)) < (pixels($1), bitrate($1)) }
        }
    }

    /// 服务器 `VideoRangeType` 的优先级：杜比视界 > HDR10+ > HDR10 / HLG > SDR / 未知。
    static func rangeRank(_ range: String?) -> Int {
        guard let range else { return 0 }
        if range.hasPrefix("DOVI") { return 3 }
        if range == "HDR10Plus" { return 2 }
        if range == "HDR10" || range == "HLG" { return 1 }
        return 0
    }
}
