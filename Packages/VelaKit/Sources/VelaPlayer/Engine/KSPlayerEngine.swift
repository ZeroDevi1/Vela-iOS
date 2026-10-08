import AVFoundation
import AVKit
import CoreVideo
import Foundation
@preconcurrency import KSPlayer
import Observation
import os
import VelaCore

/// KSPlayer 内核（KSMEPlayer：FFmpeg 解封装 + VideoToolbox 硬解 + `AVSampleBufferDisplayLayer` 显示）。
///
/// 用于系统内核无法直放的片源（MKV 等）：直接播放原文件、不经服务器转码。与系统内核一样支持画中画，
/// 并能逐帧取出解码后的 `CVPixelBuffer`，因此 VR 转平面在两种内核下都可用。
/// 线程：KSMEPlayer 的回调都在主线程；进度由 4 Hz 定时器轮询（KSMEPlayer 没有时间观察接口）。
@MainActor
@Observable
public final class KSPlayerEngine: NSObject, PlaybackEngine, EmbeddedSubtitleProviding, EnginePictureInPictureProviding,
    PictureInPictureSubtitleBurning, VideoGravityAdjustable, DecodedFrameProviding {
    public let kind: PlaybackEngineKind = .ksPlayer
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var isMuted = false
    public private(set) var networkThroughput: Double?
    public private(set) var videoSize: CGSize = .zero
    @ObservationIgnored public var preciseSeeking = false {
        didSet { options?.isAccurateSeek = preciseSeeking }
    }
    /// 解码参数；下次 `load` 生效。
    @ObservationIgnored public var configuration = Configuration()

    public struct Configuration: Sendable {
        /// 硬解（VideoToolbox）；false 为 FFmpeg 软解（耗电高，仅用于硬解失败的片源）。
        public var hardwareDecoding = true
        /// 异步硬解：解码与送显并行，高码率（4K / 8K）片源更流畅，略增内存。
        public var asynchronousDecompression = true
        /// 软解线程数，0 为自动（按 CPU 核心数）。
        public var decodeThreads = 0
        /// 杜比音频（AC-3 / E-AC-3，含 E-AC-3 JOC 杜比全景声）不解码，压缩数据直接交给系统渲染（「杜比全景声」设置）。
        /// 开启时音频输出改用 `AVSampleBufferAudioRenderer`（KSPlayer 的 `AudioRendererPlayer`，PCM 音轨同样经它输出）；
        /// 关闭时沿用 KSPlayer 默认的 `AVAudioEngine` 输出，全部解码为 PCM（macOS 上下混为立体声，全景声对象丢失）。
        public var dolbyPassthrough = true

        public init() {}
    }

    /// 渲染容器：KSMEPlayer 的视频视图挂在其中并铺满。由 `PlayerSurface` 放进视图层级。
    @ObservationIgnored public let containerView = PlayerPlatformView()
    @ObservationIgnored private var player: KSMEPlayer?
    @ObservationIgnored private var options: KSOptions?
    @ObservationIgnored private var pollTimer: Timer?
    /// 起播请求：KSMEPlayer 必须在 `readyToPlay` 之后才能 `play()`。
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var lastBytesRead: (bytes: Int64, at: CFTimeInterval)?
    @ObservationIgnored private var pollTick = 0
    @ObservationIgnored private var contentMode: UIViewContentMode = .scaleAspectFit
    /// 选中的内嵌文本字幕轨（KSPlayer 边播边从视频流解码，不需要服务器提取）；nil 为未开启。
    public private(set) var hasEmbeddedSubtitle = false
    @ObservationIgnored private var embeddedSubtitle: (any SubtitleInfo)?
    /// 本次播放已读到的内嵌字幕条目（按开始时间排序）。KSPlayer 的 `search(for:)` 会把命中的条目从解码队列中取走
    /// （它自带的字幕界面也是取出后自行保留），所以这里必须保留：否则每条字幕只在第一次查询时出现一帧。
    /// 全部保留而不只是当前条目：往回拖动时已播放过的字幕可以立即显示，不必等解码器重新读到。
    @ObservationIgnored private var activeSubtitleParts: [SubtitlePart] = []
    /// 起播前选择的字幕序号：轨道在 `readyToPlay` 后才可用，届时再应用。
    @ObservationIgnored private var pendingSubtitleOrdinal: Int?
    /// 用户选择的内嵌字幕序号；重新加载（切换码流）后自动重新选中。
    @ObservationIgnored private var selectedSubtitleOrdinal: Int?
    @ObservationIgnored private var pictureInPictureBurner: SubtitleBurner?

    public var surface: PlaybackSurface { .view(containerView) }

    public var preciseCurrentTime: TimeInterval {
        guard let player, player.isReadyToPlay else { return currentTime }
        let time = player.currentPlaybackTime
        return time.isFinite ? time : currentTime
    }

    /// 画中画控制器（`AVSampleBufferDisplayLayer` 内容源）；未起播或平台不支持时为 nil。
    public var pictureInPictureController: AVPictureInPictureController? { player?.pipController }

    override public init() {
        super.init()
        #if os(iOS)
        containerView.backgroundColor = .black
        #else
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        #endif
        // 只用 KSMEPlayer 本身，不经过 KSPlayerLayer：远程控制、正在播放与音频会话由 Vela 统一管理。
    }

    // MARK: - 播放控制

    public func load(_ source: PlaybackSource) {
        status = .loading
        currentTime = source.startTime
        duration = 0
        bufferedTime = 0
        videoSize = .zero
        networkThroughput = nil
        lastBytesRead = nil
        wantsPlay = true
        embeddedSubtitle = nil
        activeSubtitleParts = []
        pendingSubtitleOrdinal = selectedSubtitleOrdinal
        activateAudioSession()

        let options = KSOptions()
        options.hardwareDecode = configuration.hardwareDecoding
        options.asynchronousDecompression = configuration.asynchronousDecompression
        options.decoderOptions["threads"] = configuration.decodeThreads > 0 ? String(configuration.decodeThreads) : "auto"
        options.isAccurateSeek = preciseSeeking
        options.startPlayTime = source.startTime
        // 尽快出首帧：首次打开只需少量缓冲即可起播。
        options.isSecondOpen = true
        // 字幕由 Vela 统一渲染（服务器 WebVTT），不让内核解码内嵌字幕。
        options.autoSelectEmbedSubtitle = false
        options.registerRemoteControll = false
        options.displayFrameTransform = Self.frameTransform(pictureInPictureBurner)
        var dolbyPassthrough = configuration.dolbyPassthrough
        #if DEBUG
        // `VELA_DEBUG_NO_PASSTHROUGH=1`：关闭直通（与直通对比时用，不改设置）。
        if ProcessInfo.processInfo.environment["VELA_DEBUG_NO_PASSTHROUGH"] == "1" { dolbyPassthrough = false }
        #endif
        if dolbyPassthrough {
            options.audioPassthrough = { track in
                guard track.passthroughAudioFormatID != nil else { return false }
                Log.player.info("KSPlayer 音频直通：\(track.description, privacy: .public) atmos=\(track.isDolbyAtmos)")
                return true
            }
            options.videoPassthrough = { track in
                // 杜比视界 P5（IPTPQc2，无回退层）/ P8（HDR10 / HLG / SDR 兼容层）由系统解码并做杜比视界映射；
                // P7（蓝光双层）系统不支持，仍按基础层解码（HDR10）。
                var passthrough = track.doviProfile == 5 || track.doviProfile == 8
                #if DEBUG
                // `VELA_DEBUG_VIDEO_PASSTHROUGH=1`：任意 HEVC 都走直通（没有杜比视界片源时验证通路本身）。
                if ProcessInfo.processInfo.environment["VELA_DEBUG_VIDEO_PASSTHROUGH"] == "1" { passthrough = true }
                #endif
                guard passthrough, track.passthroughVideoFormatDescription != nil else { return false }
                Log.player.info("KSPlayer 视频直通：\(track.description, privacy: .public) dovi=\(track.doviProfile.map(String.init) ?? "-", privacy: .public)")
                return true
            }
        }
        if source.forwardBufferDuration > 0 {
            options.maxBufferDuration = max(source.forwardBufferDuration, options.preferredForwardBufferDuration)
        }
        if !source.httpHeaders.isEmpty { options.appendHeader(source.httpHeaders) }
        self.options = options

        // 音频输出在创建 KSMEPlayer 时按全局的 `KSOptions.audioPlayerType` 确定，替换片源时沿用；
        // 直通设置改变时须重建播放器，否则压缩帧会送进不能渲染它的输出。
        let audioOutputType: AudioOutput.Type = dolbyPassthrough ? AudioRendererPlayer.self : AudioEnginePlayer.self
        if let player, type(of: player.audioOutput) != audioOutputType {
            player.delegate = nil
            player.shutdown()
            player.view?.removeFromSuperview()
            self.player = nil
        }
        if let player {
            player.replace(url: source.url, options: options)
        } else {
            KSOptions.audioPlayerType = audioOutputType
            let player = KSMEPlayer(url: source.url, options: options)
            player.delegate = self
            self.player = player
        }
        player?.isMuted = isMuted
        player?.playbackRate = rate
        attachVideoView()
        player?.prepareToPlay()
        startPolling()
    }

    public func play() {
        wantsPlay = true
        guard let player, player.isReadyToPlay else { return }
        if status == .ended {
            Task { await seek(to: 0) }
        }
        player.play()
        updateStatus()
    }

    public func pause() {
        wantsPlay = false
        player?.pause()
        updateStatus()
    }

    public func seek(to seconds: TimeInterval) async {
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        currentTime = target
        if status == .ended { status = .paused }
        guard let player, player.isReadyToPlay else {
            options?.startPlayTime = target
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(time: target) { _ in continuation.resume() }
        }
        // KSMEPlayer 在 seek 期间把播放状态置为 seeking；完成后按用户意图恢复。
        if wantsPlay { player.play() } else { player.pause() }
        updateStatus()
    }

    public func currentFrameRate() -> Double? {
        guard let fps = player?.dynamicInfo?.displayFPS, fps > 0 else { return nil }
        return fps
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        player?.playbackRate = rate
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.isMuted = muted
    }

    public func selectAudioTrack(ordinal: Int) async -> Bool {
        guard let player else { return false }
        let tracks = player.tracks(mediaType: .audio)
        guard tracks.count > 1, tracks.indices.contains(ordinal) else { return false }
        player.select(track: tracks[ordinal])
        return true
    }

    /// 选择文件内嵌的文本字幕（按内嵌字幕轨出现顺序，从 0 开始，不含视频流里的闭路字幕）；nil 关闭。
    /// 与 Android / SenPlayer 一样由播放器自己从视频流读取字幕：服务器单独提取内嵌字幕需要读完整个文件，
    /// 文件在网盘挂载盘上时可能要数分钟。
    public func selectEmbeddedSubtitle(ordinal: Int?) {
        hasEmbeddedSubtitle = ordinal != nil
        selectedSubtitleOrdinal = ordinal
        guard let player, player.isReadyToPlay else {
            pendingSubtitleOrdinal = ordinal
            return
        }
        pendingSubtitleOrdinal = nil
        let tracks = embeddedSubtitleTracks(player)
        tracks.forEach { $0.isEnabled = false }
        embeddedSubtitle = nil
        activeSubtitleParts = []
        guard let ordinal, tracks.indices.contains(ordinal) else {
            if ordinal != nil { Log.player.error("KSPlayer 内嵌字幕：找不到第 \(ordinal ?? -1) 条（共 \(tracks.count) 条）") }
            return
        }
        player.select(track: tracks[ordinal])
        embeddedSubtitle = tracks[ordinal] as? (any SubtitleInfo)
        Log.player.info("KSPlayer 内嵌字幕：选中第 \(ordinal) 条 \(tracks[ordinal].name, privacy: .public)")
    }

    /// 当前时间应显示的内嵌字幕文字；没有字幕或此刻无字幕时为 nil。图形字幕（PGS）不在此显示。
    public func embeddedSubtitleText(at time: TimeInterval) -> String? {
        guard let embeddedSubtitle else { return nil }
        let found = embeddedSubtitle.search(for: time).filter { part in !activeSubtitleParts.contains { $0 == part } }
        if !found.isEmpty {
            activeSubtitleParts.append(contentsOf: found)
            activeSubtitleParts.sort { $0.start < $1.start }
        }
        let text = activeSubtitleParts.filter { $0 == time }
            .compactMap { $0.text?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func embeddedSubtitleTracks(_ player: KSMEPlayer) -> [any MediaPlayerTrack] {
        player.tracks(mediaType: .subtitle).filter { !$0.description.lowercased().contains("eia_608") }
    }

    /// 画中画字幕：非 nil 时每帧送入显示图层前叠加字幕（保持原帧格式，见 `SubtitleBurner.burnPreservingFormat`）。
    /// 重新加载（换码流）后沿用。
    func setPictureInPictureSubtitles(_ burner: SubtitleBurner?) {
        pictureInPictureBurner = burner
        options?.displayFrameTransform = Self.frameTransform(burner)
    }

    private static func frameTransform(_ burner: SubtitleBurner?) -> ((CVPixelBuffer) -> CVPixelBuffer?)? {
        guard let burner else { return nil }
        #if DEBUG
        // `VELA_DEBUG_DUMP_PIP=1`：把画中画期间第一帧叠字幕前后的画面写成 PNG（系统小窗无法截图，排查画面错位用）。
        if ProcessInfo.processInfo.environment["VELA_DEBUG_DUMP_PIP"] != nil {
            let dumped = OSAllocatedUnfairLock(initialState: false)
            return { source in
                let output = burner.burnPreservingFormat(source)
                if !dumped.withLock({ let was = $0; $0 = true; return was }) {
                    DebugFrameDump.write(source, name: "pip-source")
                    if let output { DebugFrameDump.write(output, name: "pip-burned") }
                }
                return output
            }
        }
        #endif
        return { burner.burnPreservingFormat($0) }
    }

    public func captureFrame() async -> CGImage? {
        await player?.thumbnailImageAtCurrentTime()
    }

    /// 画面比例：适应 / 填充（裁切）/ 拉伸。
    public func setGravity(_ gravity: PlayerController.VideoGravity) {
        contentMode = switch gravity {
        case .fit: .scaleAspectFit
        case .fill: .scaleAspectFill
        case .stretch: .scaleToFill
        }
        player?.contentMode = contentMode
    }

    /// 最近一帧解码画面（VR 转平面逐帧读取）。软解得到的帧不是 `CVPixelBuffer` 时为 nil。
    public func currentPixelBuffer() -> CVPixelBuffer? {
        player?.videoOutput?.pixelBuffer?.cvPixelBuffer
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        wantsPlay = false
        player?.delegate = nil
        embeddedSubtitle = nil
        activeSubtitleParts = []
        player?.shutdown()
        player?.view?.removeFromSuperview()
        player = nil
        options = nil
        status = .idle
    }

    #if DEBUG
    /// 画中画画面比例排查用：显示图层与视图尺寸、送出帧的像素尺寸与像素宽高比。
    func pictureInPictureDiagnostics() -> String {
        guard let output = player?.videoOutput else { return "无视频输出" }
        let layer = output.displayLayer
        var text = "layer.bounds=\(layer.bounds.size) gravity=\(layer.videoGravity.rawValue) superlayer=\(layer.superlayer?.bounds.size ?? .zero)"
        if let buffer = output.pixelBuffer?.cvPixelBuffer {
            let par = CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil)
            let aperture = CVBufferCopyAttachment(buffer, kCVImageBufferCleanApertureKey, nil)
            text += " frame=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) par=\(String(describing: par)) cleanAperture=\(String(describing: aperture))"
        }
        if let format = output.pixelBuffer?.formatDescription {
            text += " formatDimensions=\(CMVideoFormatDescriptionGetDimensions(format))"
        }
        text += " pipActive=\(pictureInPictureController?.isPictureInPictureActive ?? false)"
        return text
    }
    #endif

    // MARK: - 内部

    private func attachVideoView() {
        guard let view = player?.view, view.superview !== containerView else { return }
        view.removeFromSuperview()
        view.frame = containerView.bounds
        #if os(iOS)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.autoresizingMask = [.width, .height]
        #endif
        containerView.addSubview(view)
        player?.contentMode = contentMode
    }

    /// 4 Hz 刷新进度、缓冲与状态，与系统内核的周期观察频率一致；网速每秒计算一次。
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
        guard let player, player.isReadyToPlay else { return }
        let time = player.currentPlaybackTime
        if time.isFinite, player.playbackState != .seeking { currentTime = time }
        let playable = player.playableTime
        if playable.isFinite { bufferedTime = playable }
        // 部分片源打开时还不知道画面尺寸，首帧解码后才有。
        if videoSize == .zero, player.naturalSize != .zero { videoSize = player.naturalSize }
        pollTick += 1
        if pollTick % 4 == 0, let bytes = player.dynamicInfo?.bytesRead {
            let now = CACurrentMediaTime()
            if let last = lastBytesRead, now > last.at, bytes >= last.bytes {
                networkThroughput = Double(bytes - last.bytes) * 8 / (now - last.at)
            }
            lastBytesRead = (bytes, now)
        }
        updateStatus()
    }

    private func updateStatus() {
        guard let player else { return }
        if case .failed = status { return }
        switch player.playbackState {
        case .finished:
            status = .ended
        case .playing, .seeking:
            status = player.loadState == .playable ? (player.playbackState == .seeking ? .buffering : .playing) : .buffering
        case .paused, .stopped:
            if status != .ended { status = player.isReadyToPlay ? .paused : .loading }
        case .idle:
            status = player.isReadyToPlay ? (wantsPlay ? .buffering : .paused) : .loading
        }
    }

    /// 与系统内核相同的音频会话：静音开关下仍出声、后台继续播放、画中画可用。
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

extension KSPlayerEngine: MediaPlayerDelegate {
    public func readyToPlay(player: some MediaPlayerProtocol) {
        duration = player.duration.isFinite ? player.duration : 0
        videoSize = player.naturalSize
        attachVideoView()
        let video = player.tracks(mediaType: .video).first { $0.isEnabled }
        Log.player.info("KSPlayer readyToPlay size=\(Int(self.videoSize.width))x\(Int(self.videoSize.height)) codec=\(video?.description ?? "-", privacy: .public)")
        if wantsPlay { player.play() }
        if let pendingSubtitleOrdinal { selectEmbeddedSubtitle(ordinal: pendingSubtitleOrdinal) }
        updateStatus()
    }

    public func changeLoadState(player: some MediaPlayerProtocol) {
        updateStatus()
    }

    public func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}

    public func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}

    public func finish(player: some MediaPlayerProtocol, error: Error?) {
        if let error {
            Log.player.error("KSPlayer 播放失败：\(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        } else {
            status = .ended
        }
    }
}
