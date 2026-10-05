import Foundation

/// 「视频首选版本」：同一条目有多个版本（例如 4K 与 1080p）且未手动选择时使用哪一个。
public enum MediaVersionPreference: String, CaseIterable, Sendable {
    /// 服务器返回的第一个版本（服务器按其规则排序）。
    case serverDefault
    /// 分辨率最高，其次码率最高。
    case highestQuality
    /// 码率最低（流量或带宽受限时）。
    case lowestBitrate

    public var title: String {
        switch self {
        case .serverDefault: "默认"
        case .highestQuality: "最高画质"
        case .lowestBitrate: "最低码率"
        }
    }
}
