import Foundation

/// 播放内核偏好（设置项）。
public enum PlaybackEngineMode: String, CaseIterable, Sendable {
    /// 始终优先系统内核：硬件解码、系统级功耗优化，能效最高。系统内核不能直接打开的格式（MKV 等）
    /// 由服务器用 FFmpeg 转封装 / 转码为 HLS；系统内核播放失败时可手动「用 MPV 内核重试」。
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
    /// 是否改用 MPV 直放原文件。只有设置为 MPV 时才使用；自动模式优先能效最高的系统内核（见 `PlaybackEngineMode.auto`）。
    /// - Parameter canDirectStream: 原文件可由服务器静态串流（`SupportsDirectStream` 或 `SupportsDirectPlay`）；否则 MPV 也无从播放。
    public static func prefersMPV(mode: PlaybackEngineMode, canDirectStream: Bool) -> Bool {
        canDirectStream && mode == .mpv
    }

    /// 服务器给出的 `TranscodeReasons` 是否意味着重新编码视频；只涉及容器 / 音频时视频流为复制，画质无损。
    public static func reencodesVideo(reasons: [String]) -> Bool {
        reasons.contains {
            $0.hasPrefix("Video") || $0.contains("Bitrate") || $0.hasPrefix("Subtitle") || $0.hasPrefix("Interlaced")
                || $0.hasPrefix("RefFrames") || $0.hasPrefix("AnamorphicVideo")
        }
    }
}
