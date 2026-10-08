import Foundation

/// 播放内核偏好（设置项）。
public enum PlaybackEngineMode: String, CaseIterable, Sendable {
    /// 始终优先系统内核：硬件解码、系统级功耗优化，能效最高。系统内核不能直接打开的格式（MKV 等）
    /// 由服务器用 FFmpeg 转封装 / 转码为 HLS；系统内核播放失败时可手动「用 KSPlayer 内核重试」。
    case auto
    /// 始终使用系统内核（AVPlayer）。MKV 内嵌字幕也交给服务器提取，不自动切换。
    case system
    /// 始终使用 KSPlayer 直放原文件。
    case ksPlayer = "ksplayer"
    // 曾短暂提供的 mpv（"libmpv"）/ VLC（"vlc"）已移除：旧存储值无法解析，读取时回到默认的「自动」。

    public var title: String {
        switch self {
        case .auto: "自动"
        case .system: "AVPlayer"
        case .ksPlayer: "KSPlayer"
        }
    }
}

/// 内核选择规则（纯函数，单测覆盖）。起播流程：
/// 1. `requestedEngine` 决定按哪个内核的能力向服务器请求播放信息；
/// 2. 自动模式下若需要播放器读取内嵌字幕，`switchesToKSPlayerForSubtitle` 改按 KSPlayer 重新请求；
/// 3. 拿到服务器结果后由 `playbackEngine` 定出实际内核（服务器仍要求转码时 HLS 交给能效更高的系统内核）。
public enum PlaybackEngineChoice {
    public enum Engine: Sendable, Equatable {
        case system, ksPlayer

        /// 是否直放原文件（按 KSPlayer 能力向服务器请求，MKV 等不转码）。
        public var directPlaysOriginal: Bool { self != .system }
    }

    /// - Parameter serverDownscaled: 当前条目已改为「服务器转码为 4K」，只有系统内核能播放服务器缩放后的码流。
    public static func requestedEngine(mode: PlaybackEngineMode, serverDownscaled: Bool) -> Engine {
        guard !serverDownscaled else { return .system }
        switch mode {
        case .auto, .system: return .system
        case .ksPlayer: return .ksPlayer
        }
    }

    /// 自动模式下，按系统内核请求后要显示的字幕需要播放器读取（见 `needsPlayerSideSubtitle`）时改用 KSPlayer。
    /// 用户选了「系统」时不切换（字幕交给服务器提取，可能较慢）。
    public static func switchesToKSPlayerForSubtitle(
        mode: PlaybackEngineMode, requested: Engine, serverDownscaled: Bool, subtitleNeedsPlayer: Bool
    ) -> Bool {
        requested == .system && mode == .auto && !serverDownscaled && subtitleNeedsPlayer
    }

    /// 实际使用的内核：只有按直放内核请求且服务器允许直放原文件时才用该内核，否则（服务器转码为 HLS）用系统内核。
    public static func playbackEngine(requested: Engine, isDirectPlay: Bool) -> Engine {
        requested.directPlaysOriginal && isDirectPlay ? requested : .system
    }

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
