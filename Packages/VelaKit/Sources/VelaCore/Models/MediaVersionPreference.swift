import Foundation

/// 「视频首选版本」：同一条目有多个版本（例如 4K 与 1080p）且未手动选择时使用哪一个。
///
/// 原始值沿用旧版本的存储（`highestQuality` 即「最佳分辨率」）；旧值 `lowestBitrate` 由偏好读取时迁移为 720P。
public enum MediaVersionPreference: String, CaseIterable, Sendable {
    /// 服务器返回的第一个版本（服务器按其规则排序）。
    case serverDefault
    /// 分辨率最高，其次码率最高。
    case highestQuality
    /// 码率最高，其次分辨率最高。
    case highestBitrate
    /// 动态范围最好（杜比视界 > HDR10+ > HDR10 / HLG > SDR），其次分辨率、码率。
    case bestDynamicRange
    /// 不超过目标分辨率中最清晰的版本；都超过时取最小的一个。
    case uhd4K
    case fullHD1080
    case hd720

    public var title: String {
        switch self {
        case .serverDefault: "默认"
        case .highestQuality: "最佳分辨率"
        case .highestBitrate: "最佳码率"
        case .bestDynamicRange: "最佳动态范围"
        case .uhd4K: "4K"
        case .fullHD1080: "1080P"
        case .hd720: "720P"
        }
    }

    /// 目标分辨率档位的画面宽度（像素）；非分辨率档位为 nil。
    public var targetWidth: Int? {
        switch self {
        case .uhd4K: 3840
        case .fullHD1080: 1920
        case .hd720: 1280
        default: nil
        }
    }

    /// 读取存储值：兼容已移除的「最低码率」。
    public static func stored(_ raw: String?) -> MediaVersionPreference? {
        guard let raw else { return nil }
        if raw == "lowestBitrate" { return .hd720 }
        return MediaVersionPreference(rawValue: raw)
    }
}
