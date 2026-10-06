import Foundation

/// 播放内核偏好（设置项）。
public enum PlaybackEngineMode: String, CaseIterable, Sendable {
    /// 始终优先系统内核：硬件解码、系统级功耗优化，能效最高。系统内核不能直接打开的格式（MKV 等）
    /// 由服务器用 FFmpeg 转封装 / 转码为 HLS；系统内核播放失败时可手动「用 KSPlayer 内核重试」。
    case auto
    /// 始终使用系统内核（AVPlayer）。MKV 内嵌字幕也交给服务器提取，不自动切换。
    case system
    /// 始终使用 KSPlayer 直放原文件。旧版本保存的 "mpv" 由偏好读取时迁移到此项。
    case ksPlayer = "ksplayer"

    public var title: String {
        switch self {
        case .auto: "自动"
        case .system: "系统（AVPlayer）"
        case .ksPlayer: "KSPlayer"
        }
    }
}

/// 内核选择规则。
public enum PlaybackEngineChoice {
    /// 是否需要由播放器自己从视频流读取字幕（于是改用 KSPlayer 直放）：转封装播放（系统框架打不开的容器，如 MKV）中的内嵌文本字幕。
    /// 这类字幕若交给服务器提取，需要读完整个视频文件，网盘上的大文件可能要数分钟。
    public static func needsPlayerSideSubtitle(isTranscode: Bool, container: String?, isEmbeddedText: Bool) -> Bool {
        guard isTranscode, isEmbeddedText else { return false }
        let systemContainers: Set<String> = ["mp4", "m4v", "mov"]
        let containers = (container ?? "").lowercased().split(separator: ",").map(String.init)
        return !containers.contains { systemContainers.contains($0) }
    }

    /// 服务器给出的 `TranscodeReasons` 是否意味着重新编码视频；只涉及容器 / 音频时视频流为复制，画质无损。
    public static func reencodesVideo(reasons: [String]) -> Bool {
        reasons.contains {
            $0.hasPrefix("Video") || $0.contains("Bitrate") || $0.hasPrefix("Subtitle") || $0.hasPrefix("Interlaced")
                || $0.hasPrefix("RefFrames") || $0.hasPrefix("AnamorphicVideo")
        }
    }
}
