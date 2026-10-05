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
        switch preference {
        case .serverDefault:
            return sources.first
        case .highestQuality:
            return sources.max { (pixels($0), $0.bitrate ?? 0) < (pixels($1), $1.bitrate ?? 0) }
        case .lowestBitrate:
            return sources.min { ($0.bitrate ?? .max) < ($1.bitrate ?? .max) }
        }
    }
}
