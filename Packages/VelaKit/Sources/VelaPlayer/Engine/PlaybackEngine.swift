import AVFoundation
import AVKit
import Foundation
import VelaCore

/// 可替换的播放内核。界面与手势只依赖此协议；AVPlayer 为默认内核，KSPlayer 为备选内核。
///
/// 实现类型须为 `@Observable`，界面通过读取属性自动订阅变化。
@MainActor
public protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var status: PlaybackStatus { get }
    /// 当前位置与总时长，单位秒；直播或未知时长时 `duration` 为 0。
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    /// 已缓冲到的位置（秒）。
    var bufferedTime: TimeInterval { get }
    var rate: Float { get }
    /// 最近测得的下载速度（bit/s）；未知时为 nil。用于「播放信息」判断卡顿是否因网络带宽不足。
    var networkThroughput: Double? { get }
    /// 是否静音。静音只关闭输出，不切换或禁用音轨；在 `load` 之前设置也会在起播后生效。
    var isMuted: Bool { get }
    /// 视频画面的显示尺寸（已应用像素宽高比）；未知或纯音频时为 `.zero`。界面据此计算画面在屏幕上的位置。
    var videoSize: CGSize { get }
    /// 直接从内核读取的当前位置（秒），不经过 0.25 秒的观察刷新；用于字幕等需要帧级同步的场景。
    var preciseCurrentTime: TimeInterval { get }
    /// 视频画面渲染目标；不同内核提供不同的表面类型。
    var surface: PlaybackSurface { get }

    /// 精准定位：跳到确切的帧（需从关键帧解码，较慢）；false 时跳到附近关键帧。
    var preciseSeeking: Bool { get set }

    /// 当前实际渲染帧率；未知时为 nil。按需读取（OSD 每秒一次），不做观察。
    func currentFrameRate() -> Double?

    func load(_ source: PlaybackSource)
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func setRate(_ rate: Float)
    func setMuted(_ muted: Bool)
    /// 在当前媒体内切换音轨（按音轨出现顺序，从 0 开始）。媒体内没有可切换的音轨时返回 false，
    /// 调用方应改为请求服务器重新选流。
    func selectAudioTrack(ordinal: Int) async -> Bool
    /// 截取当前画面；内核无法提供画面（未起播、纯音频）时返回 nil。
    func captureFrame() async -> CGImage?
    /// 释放解码与网络资源。调用后实例不再可用。
    func stop()
}

// MARK: - 可选能力

// 内核特有的能力拆成可选协议，功能层按「能不能」判断（`engine as? any EmbeddedSubtitleProviding`），
// 不依赖具体内核类型。曾接入的 mpv / VLC 已移除（画中画、切换内核等问题多），只保留系统内核与 KSPlayer。

/// 能直接从视频流读取内嵌文本字幕的内核（KSPlayer）。系统内核做不到，需服务器提取字幕。
@MainActor
public protocol EmbeddedSubtitleProviding: PlaybackEngine {
    /// 当前是否选中了内嵌字幕轨（选中后才由内核解码字幕包）。
    var hasEmbeddedSubtitle: Bool { get }
    /// 按内嵌字幕轨出现顺序（从 0 开始）选择；nil 关闭。
    func selectEmbeddedSubtitle(ordinal: Int?)
    func embeddedSubtitleText(at time: TimeInterval) -> String?
}

/// 由内核自己提供画中画控制器的内核（自带画面视图、不使用 `AVPlayerLayer`，例如 KSPlayer）。
/// 系统内核走 `AVPlayerLayer` 原生画中画，不实现此协议。控制器可能在起播后才创建。
@MainActor
public protocol EnginePictureInPictureProviding: PlaybackEngine {
    var pictureInPictureController: AVPictureInPictureController? { get }
}

/// 画中画期间能把字幕叠进送出画面的内核（小窗里没有应用的字幕图层）。
@MainActor
protocol PictureInPictureSubtitleBurning: PlaybackEngine {
    func setPictureInPictureSubtitles(_ burner: SubtitleBurner?)
}

/// 自带画面视图、需由播放器同步画面比例的内核（系统内核由 `AVPlayerLayer.videoGravity` 处理）。
@MainActor
public protocol VideoGravityAdjustable: PlaybackEngine {
    func setGravity(_ gravity: PlayerController.VideoGravity)
}

/// 能提供最近一帧解码画面（`CVPixelBuffer`）的内核；VR 转平面经此取帧。系统内核改用 `AVPlayerItemVideoOutput`。
@MainActor
public protocol DecodedFrameProviding: PlaybackEngine {
    func currentPixelBuffer() -> CVPixelBuffer?
}

/// 能报告「有声无画」等视频解码问题的内核，播放页据此提示换内核或服务器转码。
@MainActor
public protocol VideoDecodeDiagnosing: PlaybackEngine {
    /// 解码问题的用户可读说明；正常时为 nil。
    var videoDecodeIssue: String? { get }
}

/// 码流自带字幕轨（服务器 HLS 的 `SUBTITLES` 组，见 `ResolvedStream.urlWithSubtitlesInManifest`）的内核：
/// 平时字幕由应用绘制、字幕轨不选中；系统画中画（只渲染播放器自己的字幕轨）期间选中对应的轨。
@MainActor
public protocol ManifestSubtitleSelecting: PlaybackEngine {
    /// 选中码流中的字幕轨：优先按名称（服务器写入的 `NAME`，即字幕流的显示标题）匹配，否则按播放列表中的序号；
    /// `ordinal` 为 nil 时取消选中。返回是否成功（码流没有字幕组或该轨时为 false）。
    func selectManifestSubtitle(ordinal: Int?, name: String?) async -> Bool
}

/// 能报告送显画面 HDR10 静态元数据的内核（播放信息显示）。系统内核由 AVPlayer 内部处理，不报告。
@MainActor
public protocol HDRMetadataReporting: PlaybackEngine {
    /// 当前画面的母版显示 / 内容亮度元数据；SDR、片源未声明或尚未出帧时为 nil。
    var hdrStaticMetadata: HDRStaticMetadata? { get }
}

/// 可控制多声道音频是否交给系统空间化处理的内核（「原生音频」设置）。
@MainActor
public protocol MultichannelSpatializationConfigurable: PlaybackEngine {
    var allowsMultichannelSpatialization: Bool { get set }
}

extension PlaybackEngine {
    /// 画面经 `AVPlayerLayer` 输出，可用系统原生画中画（含切后台自动进入）；否则需内核实现 `EnginePictureInPictureProviding`。
    public var supportsLayerPictureInPicture: Bool {
        if case .avPlayer = surface { return true }
        return false
    }

    /// 能为「VR 转平面」提供画面：系统内核经 `AVPlayerItemVideoOutput`，其余内核需实现 `DecodedFrameProviding`。
    public var supportsVRFrames: Bool {
        if case .avPlayer = surface { return true }
        return self is any DecodedFrameProviding
    }

    /// 内核能以任一方式进入系统画中画（原生图层或内核自带控制器）。macOS 不走系统画中画（见 `PlayerController.isMiniWindow`）。
    public var supportsPictureInPicture: Bool {
        supportsLayerPictureInPicture || self is any EnginePictureInPictureProviding
    }
}

public enum PlaybackEngineKind: String, Sendable, CaseIterable {
    /// 系统内核：原生 HDR10 / 杜比视界 / 空间音频 / 画中画 / AirPlay。
    case avFoundation
    /// KSPlayer（FFmpeg 解封装 + VideoToolbox 硬解）：直放 MKV 等系统框架打不开的容器，同样支持画中画与 VR 转平面。
    case ksPlayer

    /// 播放信息面板与切换菜单中显示的名称。
    public var title: String {
        switch self {
        case .avFoundation: "AVPlayer"
        case .ksPlayer: "KSPlayer"
        }
    }
}

public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

public enum PlaybackSurface {
    case avPlayer(AVPlayer)
    /// KSPlayer：内核自带的视频视图（挂在容器视图中）。
    case view(PlayerPlatformView)
}

/// 交给内核的播放请求，已与服务器无关。
public struct PlaybackSource: Sendable, Hashable {
    public var url: URL
    public var title: String
    public var subtitle: String?
    /// 起播位置（秒）；断点续播时使用。
    public var startTime: TimeInterval
    /// 部分 CDN / 直链需要的额外请求头。AVPlayer 通过私有选项注入，不保证所有分片都生效，优先使用 URL 鉴权。
    public var httpHeaders: [String: String]
    /// 识别出的 VR 排布；非 nil 时播放器提供「VR 转平面」。
    public var vrLayout: VRLayout?
    /// 前向缓冲时长（秒）；0 表示使用内核默认值（本地文件播放时）。
    public var forwardBufferDuration: TimeInterval

    public init(
        url: URL,
        title: String,
        subtitle: String? = nil,
        startTime: TimeInterval = 0,
        httpHeaders: [String: String] = [:],
        vrLayout: VRLayout? = nil,
        forwardBufferDuration: TimeInterval = 0
    ) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.startTime = startTime
        self.httpHeaders = httpHeaders
        self.vrLayout = vrLayout
        self.forwardBufferDuration = forwardBufferDuration
    }
}
