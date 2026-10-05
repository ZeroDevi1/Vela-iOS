import AVFoundation
import QuartzCore
import Foundation
import VelaCore

/// 可替换的播放内核。界面与手势只依赖此协议；AVPlayer 为默认内核，MPV / KSPlayer 后续以同一协议接入。
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

public enum PlaybackEngineKind: String, Sendable, CaseIterable {
    /// 系统内核：原生 HDR10 / 杜比视界 / 空间音频 / 画中画 / AirPlay。
    case avFoundation
    /// 预留：MPV（FFmpeg + libplacebo），用于 MKV 直放、ASS 特效字幕等。
    case mpv
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
    /// MPV：libmpv 直接绘制到该图层。
    case metalLayer(CAMetalLayer)
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
    /// 前向缓冲时长（秒）；0 表示交给内核按网络情况决定。
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
