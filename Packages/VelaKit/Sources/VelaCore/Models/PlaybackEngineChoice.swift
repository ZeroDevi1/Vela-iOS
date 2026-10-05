import Foundation

/// 播放内核偏好（设置项）。
public enum PlaybackEngineMode: String, CaseIterable, Sendable {
    /// 系统内核能直放或服务器只需转封装时用系统内核；需要因格式 / 字幕转码时改用 MPV 直放原文件。
    case auto
    /// 始终使用系统内核（AVPlayer）。
    case system
    /// 始终使用 MPV 直放原文件。
    case mpv

    public var title: String {
        switch self {
        case .auto: "自动"
        case .system: "系统（AVPlayer）"
        case .mpv: "MPV"
        }
    }
}

/// 内核选择规则。
public enum PlaybackEngineChoice {
    /// 是否改用 MPV 直放原文件。
    ///
    /// 自动模式下只在「服务器因格式 / 编码 / 字幕需要转码」时切换；因码率超限（远程带宽不足）转码时保持系统内核，
    /// 否则 MPV 直放原文件会绕过码率限制。
    /// - Parameters:
    ///   - isTranscode: 系统内核选流结果是否为服务器转码。
    ///   - reasons: 服务器给出的 `TranscodeReasons`。
    ///   - canDirectStream: 原文件可由服务器静态串流（`SupportsDirectStream` 或 `SupportsDirectPlay`）。
    public static func prefersMPV(mode: PlaybackEngineMode, isTranscode: Bool, reasons: [String], canDirectStream: Bool) -> Bool {
        guard canDirectStream else { return false }
        switch mode {
        case .system: return false
        case .mpv: return true
        case .auto:
            guard isTranscode else { return false }
            let bitrateLimited = reasons.contains { $0.contains("Bitrate") }
            return !bitrateLimited
        }
    }
}
