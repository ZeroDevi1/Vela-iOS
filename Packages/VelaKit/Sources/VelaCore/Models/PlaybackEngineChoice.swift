import Foundation

/// 播放内核偏好（设置项）。
public enum PlaybackEngineMode: String, CaseIterable, Sendable {
    /// 始终优先系统内核：硬件解码、系统级功耗优化，能效最高。系统内核不能直接打开的格式（MKV 等）
    /// 由服务器用 FFmpeg 转封装 / 转码为 HLS；系统内核播放失败时自动改用 KSPlayer（见 `PlaybackEngineChoice.fallsBackToKSPlayer`）。
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
    /// 用户选了「系统」时不切换（字幕交给服务器提取，可能较慢）；片源有系统内核更擅长的特性
    /// （`KSPlayerLimitation.prefersSystem`）时也不切换，画质 / 音质优先于字幕等待时间。
    public static func switchesToKSPlayerForSubtitle(
        mode: PlaybackEngineMode, requested: Engine, serverDownscaled: Bool, subtitleNeedsPlayer: Bool,
        limitation: KSPlayerLimitation? = nil
    ) -> Bool {
        requested == .system && mode == .auto && !serverDownscaled && subtitleNeedsPlayer
            && limitation?.prefersSystem != true
    }

    /// 片源中与内核选择有关的特性（来自服务器媒体信息）。
    public struct SourceTraits: Sendable, Equatable {
        /// 蓝光 / DVD 原盘（BDMV、VIDEO_TS 或 ISO）。
        public var isDiscImage: Bool
        /// 杜比视界 Profile；非杜比视界为 nil。
        public var dolbyVisionProfile: Int?
        /// 要播放的音轨是 E-AC-3 杜比全景声（TrueHD 全景声两个内核都只能解码为 PCM，不计入）。
        public var isAtmosEAC3: Bool

        public init(isDiscImage: Bool = false, dolbyVisionProfile: Int? = nil, isAtmosEAC3: Bool = false) {
            self.isDiscImage = isDiscImage
            self.dolbyVisionProfile = dolbyVisionProfile
            self.isAtmosEAC3 = isAtmosEAC3
        }
    }

    /// KSPlayer 播放该片源时不如系统内核之处；nil 为没有差别（HDR10 / HDR10+ / 杜比直通下的杜比视界 P5、P8 等）。
    /// - Parameter passthrough: KSPlayer 杜比直通是否开启（设置「杜比全景声」）。
    public static func ksPlayerLimitation(_ traits: SourceTraits, passthrough: Bool) -> KSPlayerLimitation? {
        if traits.isDiscImage { return .discImage }
        if let profile = traits.dolbyVisionProfile, profile == 5 || profile == 8, !passthrough {
            return .dolbyVisionDecoded(profile: profile)
        }
        if traits.isAtmosEAC3 { return .atmosObjects }
        if traits.dolbyVisionProfile == 7 { return .dolbyVisionProfile7 }
        return nil
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

    /// 系统内核在播放中遇到的问题。
    public enum SystemEngineFailure: Sendable, Equatable {
        /// 内核报错（`AVPlayerItem` 失败）。
        case error
        /// 有声音但解不出画面；`width` 为片源视频宽度，未知为 nil。
        case noVideoOutput(width: Int?)
    }

    /// 无画面时只对不超过该宽度的片源改用 KSPlayer：4K 以内多为编码标签（如 `hev1`）不被系统接受，KSPlayer 可绕过；
    /// 更宽的片源（8K 等）多半超过本机硬件解码上限，KSPlayer 同样解不动，留给「服务器转码为 4K」。
    public static let noVideoFallbackMaxWidth = 3840

    /// 系统内核失败后是否自动改用 KSPlayer 从当前位置继续，不必让用户手动重试。
    /// 只在自动模式下进行（选了「AVPlayer」时保留错误界面）；「服务器转码为 4K」的码流和原盘只有系统内核能播放；
    /// 同一条目只回退一次：按 KSPlayer 请求后服务器仍可能要求转码而回到系统内核，再失败就交给错误界面，避免来回切换。
    public static func fallsBackToKSPlayer(
        after failure: SystemEngineFailure, mode: PlaybackEngineMode, serverDownscaled: Bool, isDiscImage: Bool, alreadyFellBack: Bool
    ) -> Bool {
        guard mode == .auto, !serverDownscaled, !isDiscImage, !alreadyFellBack else { return false }
        if case .noVideoOutput(let width?) = failure, width > noVideoFallbackMaxWidth { return false }
        return true
    }

    /// 服务器给出的 `TranscodeReasons` 是否意味着重新编码视频；只涉及容器 / 音频时视频流为复制，画质无损。
    public static func reencodesVideo(reasons: [String]) -> Bool {
        reasons.contains {
            $0.hasPrefix("Video") || $0.contains("Bitrate") || $0.hasPrefix("Subtitle") || $0.hasPrefix("Interlaced")
                || $0.hasPrefix("RefFrames") || $0.hasPrefix("AnamorphicVideo")
        }
    }
}

/// KSPlayer 相对系统内核的限制（阶段 4c）：自动模式据此留在系统内核，用户手动使用 KSPlayer 时提示。
public enum KSPlayerLimitation: Sendable, Equatable {
    /// 原盘：KSPlayer 读不了原盘结构（GPL 版不含蓝光读取），只能由服务器转封装后用系统内核播放。
    case discImage
    /// 杜比视界 P5 / P8 未开杜比直通：KSPlayer 只解码基础层（P5 为 IPTPQc2，颜色异常；P8 按 HDR10 显示）。
    case dolbyVisionDecoded(profile: Int)
    /// E-AC-3 杜比全景声：KSPlayer 直通时系统渲染器只输出 5.1 床声道（`AVSampleBufferAudioRenderer` 不开放全景声对象渲染），
    /// 关闭直通则解码为 PCM；系统内核（AVPlayer）可渲染全景声对象。
    case atmosObjects
    /// 杜比视界 P7（蓝光双层）：Apple 系统不支持，KSPlayer 按 HDR10 基础层播放，与系统内核经服务器转码的效果相当。
    case dolbyVisionProfile7

    /// 自动模式是否因此留在系统内核。P7 两个内核都只能按基础层播放，不影响选择。
    public var prefersSystem: Bool {
        self != .dolbyVisionProfile7
    }

    /// 播放页提示。
    public var message: String {
        switch self {
        case .discImage:
            "蓝光 / DVD 原盘由服务器转封装播放，已使用系统内核"
        case .dolbyVisionDecoded(profile: 5):
            "未开启杜比直通，KSPlayer 播放杜比视界 Profile 5 颜色会异常。请在「音频设置」开启「杜比全景声」或使用系统内核"
        case .dolbyVisionDecoded:
            "未开启杜比直通，KSPlayer 按 HDR10 显示杜比视界。开启「音频设置 → 杜比全景声」或使用系统内核可获得杜比视界"
        case .atmosObjects:
            "KSPlayer 下杜比全景声只输出 5.1 声道，完整全景声请使用系统内核"
        case .dolbyVisionProfile7:
            "杜比视界 Profile 7 按 HDR10 基础层播放（系统不支持 Profile 7）"
        }
    }
}
