import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation
import VelaCore
@preconcurrency import VLCKit

/// VLC 内核（VLCKit 4，libvlc 4）。用于与系统内核 / KSPlayer / mpv 横向对比测试。
///
/// 能力范围（未实现的能力由播放器提示切换内核，不静默失效）：
/// - 直放 MKV 等任意容器；内嵌字幕（含 ASS 特效）由 libvlc 直接画进画面，所以 `embeddedSubtitleText` 恒为 nil
/// - 画中画（仅 iOS）：经 `VLCVideoContainerView` 接 VLCKit 4 的窗口控制协议（不支持切后台自动进入，见 `WindowPictureInPictureProviding`）。
///   macOS 的 libvlc 视频输出为 OpenGL（`vout_macosx`），不创建画中画控制器
/// - 网速 / 帧率：由 libvlc 媒体统计的累计计数按时间差折算（`VLCRateMeter`）
/// - 不实现：VR 取帧
/// - HTTP 请求头：libvlc 只支持 User-Agent / Referer，其余请求头无法注入，依赖 URL 鉴权（Jellyfin / Emby 的 api_key）
/// 线程：VLCMediaPlayer 的属性在主线程读写；进度由 4 Hz 定时器轮询，与其他内核一致。
@MainActor
@Observable
public final class VLCPlaybackEngine: NSObject, PlaybackEngine, EmbeddedSubtitleProviding, VideoGravityAdjustable {
    public let kind: PlaybackEngineKind = .vlc
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var isMuted = false
    public private(set) var networkThroughput: Double?
    public private(set) var videoSize: CGSize = .zero
    /// libvlc 按时间定位本身就是精确定位（解码到目标帧），此开关不影响行为。
    @ObservationIgnored public var preciseSeeking = false
    public private(set) var hasEmbeddedSubtitle = false

    /// 渲染容器：libvlc 在其中创建自己的视频视图并铺满。由 `PlayerSurface` 放进视图层级。
    @ObservationIgnored let containerView = VLCVideoContainerView()
    @ObservationIgnored private let player: VLCMediaPlayer
    /// libvlc 视频输出创建后交回的画中画窗口控制对象；换媒体时视频输出重建，会再次交回。
    @ObservationIgnored private var pictureInPicture: (any VLCPictureInPictureWindowControlling)?
    @ObservationIgnored public var onPictureInPictureStateChange: ((Bool) -> Void)?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var wantsPlay = false
    /// 起播位置（秒）：通过 `:start-time` 媒体选项交给 libvlc，避免先从 0 开始再跳。
    @ObservationIgnored private var startTime: TimeInterval = 0
    @ObservationIgnored private var gravity: PlayerController.VideoGravity = .fit
    /// 起播前选择的内嵌字幕序号：轨道在打开媒体后才可用。
    @ObservationIgnored private var pendingSubtitleOrdinal: Int??
    /// 曾经进入过播放：libvlc 在播放结束与主动停止时都报告 `stopped`，用它区分「结束」与「尚未起播」。
    @ObservationIgnored private var didStartPlaying = false
    @ObservationIgnored private var rates = VLCRateMeter()

    public var surface: PlaybackSurface { .view(containerView) }

    public var preciseCurrentTime: TimeInterval {
        guard let ms = player.time.value?.doubleValue else { return currentTime }
        return ms / 1000
    }

    override public init() {
        player = VLCMediaPlayer()
        super.init()
        #if os(iOS)
        containerView.backgroundColor = .black
        #else
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        #endif
        containerView.handlers = .init(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            seekBy: { [weak self] offset in
                guard let self else { return }
                await self.seek(to: self.currentTime + Double(offset) / 1000)
            },
            ready: { [weak self] controller in self?.adoptPictureInPicture(controller) }
        )
        player.drawable = containerView
    }

    // MARK: - 播放控制

    public func load(_ source: PlaybackSource) {
        status = .loading
        currentTime = source.startTime
        duration = 0
        bufferedTime = 0
        videoSize = .zero
        wantsPlay = true
        didStartPlaying = false
        progress.reset()
        rates = VLCRateMeter()
        networkThroughput = nil
        startTime = source.startTime
        activateAudioSession()

        guard let media = VLCMedia(url: source.url) else {
            status = .failed("VLC 无法打开该地址")
            return
        }
        if source.startTime > 0 { media.addOption(":start-time=\(String(format: "%.3f", source.startTime))") }
        if source.forwardBufferDuration > 0 {
            media.addOption(":network-caching=\(Int(source.forwardBufferDuration * 1000))")
        }
        if let agent = source.httpHeaders.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
            media.addOption(":http-user-agent=\(agent)")
        }
        if let referer = source.httpHeaders.first(where: { $0.key.caseInsensitiveCompare("Referer") == .orderedSame })?.value {
            media.addOption(":http-referrer=\(referer)")
        }
        // 字幕默认关闭，由播放器的选择决定（与其他内核一致）。
        media.addOption(":no-sub-autodetect-file")
        player.media = media
        player.rate = rate
        player.audio?.isMuted = isMuted
        player.play()
        startPolling()
    }

    public func play() {
        wantsPlay = true
        if status == .ended {
            Task { await seek(to: 0) }
        }
        player.play()
    }

    public func pause() {
        wantsPlay = false
        player.pause()
        updateStatus()
    }

    public func seek(to seconds: TimeInterval) async {
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        currentTime = target
        progress.reset()
        if status == .ended {
            status = .paused
            player.play()
        }
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
    }

    public func currentFrameRate() -> Double? { rates.frameRate }

    public func setRate(_ rate: Float) {
        self.rate = rate
        player.rate = rate
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        player.audio?.isMuted = muted
    }

    public func selectAudioTrack(ordinal: Int) async -> Bool {
        let tracks = player.audioTracks
        guard tracks.count > 1, tracks.indices.contains(ordinal) else { return false }
        tracks[ordinal].isSelectedExclusively = true
        return true
    }

    /// 选择内嵌字幕（按内嵌字幕轨出现顺序，从 0 开始）；nil 关闭。字幕由 libvlc 画进画面。
    public func selectEmbeddedSubtitle(ordinal: Int?) {
        hasEmbeddedSubtitle = ordinal != nil
        let tracks = player.textTracks
        guard !tracks.isEmpty else {
            // 媒体还没打开，轨道列表为空：打开后再应用。
            pendingSubtitleOrdinal = .some(ordinal)
            return
        }
        pendingSubtitleOrdinal = nil
        guard let ordinal, tracks.indices.contains(ordinal) else {
            player.deselectAllTextTracks()
            return
        }
        tracks[ordinal].isSelectedExclusively = true
    }

    /// libvlc 自己渲染字幕，不提供文字。
    public func embeddedSubtitleText(at time: TimeInterval) -> String? { nil }

    /// libvlc 的快照异步写入文件：写到临时目录后最多等 2 秒读取。
    public func captureFrame() async -> CGImage? {
        guard videoSize != .zero else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "vela-vlc-\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: url.path, withWidth: Int32(videoSize.width), andHeight: Int32(videoSize.height))
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        return nil
    }

    /// 适应：恢复原始比例；填充：按视图比例裁切；拉伸：把显示宽高比强制为视图比例。
    public func setGravity(_ gravity: PlayerController.VideoGravity) {
        self.gravity = gravity
        applyGravity()
    }

    public func stop() {
        pictureInPicture?.stopPictureInPicture()
        pictureInPicture = nil
        containerView.handlers = nil
        pollTimer?.invalidate()
        pollTimer = nil
        wantsPlay = false
        player.stop()
        // 不能写 `player.media = nil`：VLCKit 4.0.0a19 会把空媒体转给自己的「媒体已切换」回调，
        // 在 `libvlc_media_retain` 断言失败直接中止进程（macOS 关闭播放窗口时闪退）。媒体随播放器一起释放。
        player.drawable = nil
        status = .idle
    }

    // MARK: - 画中画

    private func adoptPictureInPicture(_ controller: any VLCPictureInPictureWindowControlling) {
        controller.stateChangeEventHandler = { [weak self] started in
            // 回调线程未在文档中约定，统一转到主线程。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onPictureInPictureStateChange?(started) }
            }
        }
        pictureInPicture = controller
        Log.player.info("VLC 画中画就绪")
    }

    private func publishSnapshot() {
        containerView.update(.init(
            timeMs: Int64(currentTime * 1000),
            lengthMs: Int64(duration * 1000),
            isPlaying: wantsPlay && status != .ended,
            isSeekable: player.isSeekable
        ))
    }

    // MARK: - 内部

    private func applyGravity() {
        let bounds = containerView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let divisor = gcd(Int(bounds.width), Int(bounds.height))
        let ratio = "\(Int(bounds.width) / max(divisor, 1)):\(Int(bounds.height) / max(divisor, 1))"
        switch gravity {
        case .fit:
            player.videoAspectRatio = nil
            player.setCropRatioWithNumerator(0, denominator: 0)
        case .fill:
            player.videoAspectRatio = nil
            player.setCropRatioWithNumerator(UInt32(bounds.width), denominator: UInt32(bounds.height))
        case .stretch:
            player.setCropRatioWithNumerator(0, denominator: 0)
            player.videoAspectRatio = ratio
        }
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        let time = player.time.value.map { $0.doubleValue / 1000 }
        if let time { currentTime = time }
        if let length = player.media?.length.value?.doubleValue, length > 0 {
            duration = length / 1000
        }
        // libvlc 没有直接的「已缓冲到」接口：播放中视为至少缓冲到当前位置，避免进度条缓冲段落后于播放头。
        bufferedTime = max(bufferedTime, currentTime)
        let size = player.videoSize
        if size.width > 0, size.height > 0, size != videoSize {
            if videoSize == .zero {
                Log.player.info("VLC readyToPlay size=\(Int(size.width))x\(Int(size.height))")
            }
            videoSize = size
            applyGravity()
        }
        if let pending = pendingSubtitleOrdinal, !player.textTracks.isEmpty {
            selectEmbeddedSubtitle(ordinal: pending)
        }
        updateStatus(time: time)
        publishSnapshot()
        if let stats = player.media?.statistics {
            rates.record(readBytes: stats.readBytes, displayedPictures: stats.displayedPictures, at: .now)
            if let throughput = rates.throughput, throughput != networkThroughput { networkThroughput = throughput }
        }
    }

    @ObservationIgnored private var progress = VLCProgressTracker()

    /// libvlc 4 在正常播放中也会持续报告 `buffering`（收到缓冲事件即切换），不能只看状态：
    /// `isPlaying` 为真时，时间近期在前进就是播放中，停住超过宽限期才算缓冲。
    private func updateStatus(time: TimeInterval? = nil) {
        if case .failed = status { return }
        let now = Date.now
        if let time { progress.record(time, at: now) }
        switch player.state {
        case .error:
            Log.player.error("VLC 播放失败")
            status = .failed("VLC 无法播放该片源")
        case .stopped, .stopping:
            if didStartPlaying {
                status = .ended
                pollTimer?.invalidate()
                pollTimer = nil
            }
        case .paused:
            status = .paused
        case .opening:
            status = .loading
        case .playing, .buffering:
            guard player.isPlaying else {
                status = didStartPlaying ? .paused : .loading
                return
            }
            if progress.isAdvancing(at: now) || player.state == .playing {
                didStartPlaying = true
                status = .playing
            } else {
                status = didStartPlaying ? .buffering : .loading
            }
        @unknown default:
            break
        }
    }

    /// 与其他内核相同的音频会话：静音开关下仍出声、后台继续播放。
    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
        } catch {
            Log.player.error("音频会话配置失败：\(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}

#if os(iOS)
extension VLCPlaybackEngine: WindowPictureInPictureProviding {
    public var isPictureInPictureReady: Bool { pictureInPicture != nil }

    public var allowsAutomaticPictureInPicture: Bool {
        get { containerView.canStartPictureInPictureAutomaticallyFromInline() }
        set { containerView.setAutomaticPictureInPictureAllowed(newValue) }
    }

    /// libvlc 的 `samplebufferdisplay` 把字幕画在独立的叠加视图上，送往小窗的帧不含字幕（VLCKit 内部固定，无法配置）。
    public var showsSubtitlesInPictureInPicture: Bool { false }

    public func startPictureInPicture() { pictureInPicture?.startPictureInPicture() }

    public func stopPictureInPicture() { pictureInPicture?.stopPictureInPicture() }

    public func invalidatePictureInPicturePlaybackState() {
        publishSnapshot()
        pictureInPicture?.invalidatePlaybackState()
    }
}
#endif

/// 判断 libvlc 的播放位置是否「近期在前进」。
///
/// VLCKit 4 的 `time` 只按 `minimalTimePeriod`（默认 500 ms）刷新，而引擎按 250 ms 轮询，
/// 相邻两次轮询读到同一个值是常态；若据此判为缓冲，加载圈会在播放中反复闪现。
/// 因此以「最近一次前进距今是否在宽限期内」判断，宽限期取刷新间隔的 3 倍。
struct VLCProgressTracker {
    var stallGrace: TimeInterval = 1.5
    private var lastTime: TimeInterval?
    private var lastAdvance: Date?

    mutating func record(_ time: TimeInterval, at date: Date) {
        if let lastTime, time > lastTime { lastAdvance = date }
        lastTime = time
    }

    func isAdvancing(at date: Date) -> Bool {
        guard let lastAdvance else { return false }
        return date.timeIntervalSince(lastAdvance) <= stallGrace
    }

    /// 起播与跳转后调用：跳转造成的时间跳变不算播放前进，需重新观察。
    mutating func reset() {
        lastTime = nil
        lastAdvance = nil
    }
}

/// 把 libvlc 媒体统计的累计计数（已读字节、已显示帧）折算为速率。
///
/// 不用统计里的 `inputBitrate`：其单位未在头文件中说明，且缓冲区满时为 0。累计计数为 Int32，
/// 超过 2 GB 会回绕成负数，出现回退时丢弃这一段重新开始。每满 1 秒结算一次，避免 4 Hz 轮询带来的抖动。
struct VLCRateMeter {
    /// 最近一次测得的下载速度（bit/s）。缓冲区已满、暂时没有下载时保留上一次的值。
    private(set) var throughput: Double?
    /// 最近 1 秒实际显示的帧率；暂停或未出画面时为 nil。
    private(set) var frameRate: Double?
    private var window: (date: Date, bytes: Int32, pictures: Int32)?
    static let interval: TimeInterval = 1

    mutating func record(readBytes: Int32, displayedPictures: Int32, at date: Date) {
        guard let start = window else {
            window = (date, readBytes, displayedPictures)
            return
        }
        let elapsed = date.timeIntervalSince(start.date)
        guard elapsed >= Self.interval else { return }
        window = (date, readBytes, displayedPictures)
        let bytes = Int64(readBytes) - Int64(start.bytes)
        let pictures = Int64(displayedPictures) - Int64(start.pictures)
        guard bytes >= 0, pictures >= 0 else { return }
        if bytes > 0 { throughput = Double(bytes) * 8 / elapsed }
        frameRate = pictures > 0 ? Double(pictures) / elapsed : nil
    }
}
