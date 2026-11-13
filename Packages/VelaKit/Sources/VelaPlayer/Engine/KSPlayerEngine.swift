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
/// KSMEPlayer 在主线程回报状态变化；进度由定时器采样，播放时 4 Hz，暂停时 1 Hz。
@MainActor
@Observable
public final class KSPlayerEngine: NSObject, PlaybackEngine, EmbeddedSubtitleProviding, EnginePictureInPictureProviding,
    PictureInPictureSubtitleBurning, VideoGravityAdjustable, DecodedFrameProviding, HDRMetadataReporting, PlaybackMediaInfoProviding {
    public let kind: PlaybackEngineKind = .ksPlayer
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var pendingSeekPosition: TimeInterval?
    public private(set) var rate: Float = 1
    public private(set) var isMuted = false
    public private(set) var networkThroughput: Double?
    public private(set) var videoSize: CGSize = .zero
    public private(set) var mediaInfo: PlaybackMediaInfo?
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
    @ObservationIgnored private var options: SeekBufferOptions?
    @ObservationIgnored private var isNetworkSource = false
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var seekAttempt: SeekAttempt?
    @ObservationIgnored private var seekRevision = UUID()
    @ObservationIgnored private var pollTimer: Timer?
    /// 起播请求：KSMEPlayer 必须在 `readyToPlay` 之后才能 `play()`。
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var lastBytesRead: (bytes: Int64, at: CFTimeInterval)?
    @ObservationIgnored private var pollTick = 0
    /// 本次播放是否已记录过 HDR 元数据（首帧送显后记录一次，排查色调映射用）。
    @ObservationIgnored private var hasLoggedHDRMetadata = false
    @ObservationIgnored private var contentMode: UIViewContentMode = .scaleAspectFit
    /// 选中的内嵌字幕轨（文本或 PGS），不需要服务器提取。
    public private(set) var hasEmbeddedSubtitle = false
    @ObservationIgnored private var embeddedSubtitle: (any SubtitleInfo)?
    /// 本次播放已读到的内嵌字幕条目（按开始时间排序）。KSPlayer 的 `search(for:)` 会把命中的条目从解码队列中取走
    /// （它自带的字幕界面也是取出后自行保留），所以这里必须保留：否则每条字幕只在第一次查询时出现一帧。
    /// 全部保留而不只是当前条目：往回拖动时已播放过的字幕可以立即显示，不必等解码器重新读到。
    @ObservationIgnored private var activeSubtitleParts: [SubtitlePart] = []
    @ObservationIgnored private var isImageSubtitle = false
    @ObservationIgnored private var subtitleImageCache: [ObjectIdentifier: CGImage] = [:]
    /// 起播前选择的字幕序号：轨道在 `readyToPlay` 后才可用，届时再应用。
    @ObservationIgnored private var pendingSubtitleOrdinal: Int?
    /// 用户选择的内嵌字幕序号；重新加载（切换码流）后自动重新选中。
    @ObservationIgnored private var selectedSubtitleOrdinal: Int?
    @ObservationIgnored private var pictureInPictureBurner: SubtitleBurner?

    public var surface: PlaybackSurface { .view(containerView) }

    public var preciseCurrentTime: TimeInterval {
        guard pendingSeekPosition == nil, let player, player.isReadyToPlay else { return currentTime }
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
        cancelSeek()
        isNetworkSource = SeekBufferPolicy.isNetworkSource(source.url)
        status = .loading
        updatePolling()
        currentTime = source.startTime
        duration = 0
        bufferedTime = 0
        videoSize = .zero
        mediaInfo = nil
        networkThroughput = nil
        lastBytesRead = nil
        hasLoggedHDRMetadata = false
        wantsPlay = true
        embeddedSubtitle = nil
        activeSubtitleParts = []
        subtitleImageCache = [:]
        pendingSubtitleOrdinal = selectedSubtitleOrdinal
        activateAudioSession()

        let options = SeekBufferOptions()
        options.hardwareDecode = configuration.hardwareDecoding
        options.asynchronousDecompression = configuration.asynchronousDecompression
        options.decoderOptions["threads"] = configuration.decodeThreads > 0 ? String(configuration.decodeThreads) : "auto"
        options.isAccurateSeek = preciseSeeking
        options.startPlayTime = source.startTime
        // 高码率网络文件先攒够恢复门槛，避免出首帧后立即耗尽；本地 / 普通码率保留快速起播。
        options.isSecondOpen = source.forwardBufferDuration <= 0 || (source.bitrate ?? 0) < 40_000_000
        // 由 Vela 显式选轨后统一渲染文字 / PGS，不让内核按默认轨自动开启。
        options.autoSelectEmbedSubtitle = false
        options.isSeekImageSubtitle = true
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
            options.preferredForwardBufferDuration = PlayerPreferences.rebufferDuration(
                bitrate: source.bitrate, maximumDuration: options.maxBufferDuration
            )
        }
        Log.player.info("KSPlayer 缓冲策略：resume=\(options.preferredForwardBufferDuration)s max=\(options.maxBufferDuration)s fastOpen=\(options.isSecondOpen) bitrate=\(source.bitrate ?? 0)")
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
            // replace 会停止旧片源，忽略它在替换时同步发出的状态变化。
            player.delegate = nil
            player.replace(url: source.url, options: options)
            player.delegate = self
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
    }

    public func play() {
        wantsPlay = true
        guard let player, player.isReadyToPlay else { return }
        if pendingSeekPosition != nil {
            updateStatus()
            return
        }
        if status == .ended {
            Task { await seek(to: 0) }
            return
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
        guard seconds.isFinite, !Task.isCancelled else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        guard let player, player.isReadyToPlay, let options else {
            currentTime = target
            options?.startPlayTime = target
            return
        }

        seekRevision = UUID()
        pendingSeekPosition = target
        if seekTask == nil {
            seekTask = Task { [weak self] in
                await self?.performSeeks(player: player, options: options)
            }
        }
        await seekTask?.value
    }

    private func performSeeks(player: KSMEPlayer, options: SeekBufferOptions) async {
        // FFmpeg 同时只保留一个 seek 回调。先等当前跳转返回，再处理最新目标，避免回调被覆盖。
        while let target = pendingSeekPosition, !Task.isCancelled {
            let revision = seekRevision
            let shouldBuffer = isNetworkSource && player.seekable && wantsPlay && duration - target > 0.1
            let deadline = ContinuousClock.now + SeekBufferPolicy.maximumWait
            if isImageSubtitle {
                activeSubtitleParts = []
                subtitleImageCache = [:]
            }
            let finished = await withCheckedContinuation { continuation in
                let attempt = SeekAttempt(continuation: continuation)
                seekAttempt = attempt
                player.seek(time: target) { [weak attempt] finished in
                    MainActor.assumeIsolated { attempt?.complete(finished) }
                }
                updateStatus()
            }
            guard !Task.isCancelled else { return }
            seekAttempt = nil
            guard revision == seekRevision else { continue }

            let sampleBeforeBuffering = options.bufferSample.revision
            if finished, shouldBuffer {
                while wantsPlay, revision == seekRevision, !Task.isCancelled, ContinuousClock.now < deadline {
                    let sample = options.bufferSample
                    let required = SeekBufferPolicy.targetDuration(
                        at: target, duration: duration, rate: rate, bufferLimit: options.maxBufferDuration
                    )
                    if sample.revision != sampleBeforeBuffering, sample.isPlayable,
                       sample.isEndOfFile || (sample.loadedTime.isFinite && sample.loadedTime + 0.1 >= required) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            guard !Task.isCancelled else { return }
            guard revision == seekRevision else { continue }
            pendingSeekPosition = nil
            seekTask = nil
            if finished {
                currentTime = target
                let playable = player.playableTime
                bufferedTime = playable.isFinite ? max(target, playable) : target
            }
            if status == .ended { status = .paused }
            if wantsPlay { player.play() } else { player.pause() }
            updateStatus()
            return
        }
    }

    private func cancelSeek() {
        seekTask?.cancel()
        seekTask = nil
        seekAttempt?.complete(false)
        seekAttempt = nil
        pendingSeekPosition = nil
    }

    @MainActor
    private final class SeekAttempt {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func complete(_ finished: Bool) {
            continuation?.resume(returning: finished)
            continuation = nil
        }
    }

    private final class SeekBufferOptions: KSOptions {
        struct BufferSample: Sendable {
            var revision = 0
            var loadedTime: TimeInterval = 0
            var isPlayable = false
            var isEndOfFile = false
        }

        private let sample = OSAllocatedUnfairLock(initialState: BufferSample())
        var bufferSample: BufferSample { sample.withLock { $0 } }

        override func playable(capacitys: [any CapacityProtocol], isFirst: Bool, isSeek: Bool) -> LoadingState {
            let state = super.playable(capacitys: capacitys, isFirst: isFirst, isSeek: isSeek)
            let snapshot = BufferSample(loadedTime: state.loadedTime, isPlayable: state.isPlayable, isEndOfFile: state.isEndOfFile)
            sample.withLock {
                let revision = $0.revision &+ 1
                $0 = snapshot
                $0.revision = revision
            }
            return state
        }
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
        mediaInfo?.audio = tracks[ordinal].description
        mediaInfo?.audioStreamIndex = Int(tracks[ordinal].trackID)
        return true
    }

    /// 选择文件内嵌的文本 / PGS 字幕（按字幕轨出现顺序，从 0 开始，不含闭路字幕）；nil 关闭。
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
        subtitleImageCache = [:]
        isImageSubtitle = false
        guard let ordinal, tracks.indices.contains(ordinal) else {
            if ordinal != nil { Log.player.error("KSPlayer 内嵌字幕：找不到第 \(ordinal ?? -1) 条（共 \(tracks.count) 条）") }
            return
        }
        player.select(track: tracks[ordinal])
        embeddedSubtitle = tracks[ordinal] as? (any SubtitleInfo)
        isImageSubtitle = tracks[ordinal].isImageSubtitle
        Log.player.info("KSPlayer 内嵌字幕：选中第 \(ordinal) 条 \(tracks[ordinal].name, privacy: .public)")
    }

    private func subtitleParts(at time: TimeInterval) -> [SubtitlePart] {
        guard let embeddedSubtitle else { return [] }
        let found = embeddedSubtitle.search(for: time).filter { part in !activeSubtitleParts.contains { $0 === part } }
        if !found.isEmpty {
            activeSubtitleParts.append(contentsOf: found)
            activeSubtitleParts.sort { $0.start < $1.start }
            // PGS 通过新的显示集（包括空白清除包）结束上一幅图，end 常为 infinity。
            // 只保留最新显示集，避免字幕叠影以及整部电影的位图常驻内存。
            if isImageSubtitle, let latest = activeSubtitleParts.last?.start {
                activeSubtitleParts.removeAll { $0.start < latest }
                let ids = Set(activeSubtitleParts.map(ObjectIdentifier.init))
                subtitleImageCache = subtitleImageCache.filter { ids.contains($0.key) }
            }
        }
        return activeSubtitleParts.filter { $0 == time }
    }

    public func embeddedSubtitleText(at time: TimeInterval) -> String? {
        let text = subtitleParts(at: time)
            .compactMap { $0.text?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func embeddedSubtitleImages(at time: TimeInterval) -> [EmbeddedSubtitleImage] {
        guard isImageSubtitle else { return [] }
        return subtitleParts(at: time).compactMap { part in
            guard let bitmap = part.image else { return nil }
            let id = ObjectIdentifier(part)
            let image: CGImage?
            if let cached = subtitleImageCache[id] { image = cached } else {
                #if os(macOS)
                image = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                image = bitmap.cgImage
                #endif
                subtitleImageCache[id] = image
                if image != nil {
                    Log.player.debug("PGS 显示集：\(part.start)s canvas=\(Int(part.imageCanvasSize.width))x\(Int(part.imageCanvasSize.height)) origin=\(Int(part.origin.x)),\(Int(part.origin.y))")
                }
            }
            guard let image, part.imageCanvasSize.width > 0, part.imageCanvasSize.height > 0 else { return nil }
            return EmbeddedSubtitleImage(image: image, origin: part.origin, canvasSize: part.imageCanvasSize)
        }
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

    /// 解码画面上的元数据；直通（没有解码画面）或尚未出帧时退回容器声明的值。
    public var hdrStaticMetadata: HDRStaticMetadata? {
        if let pixelBuffer = currentPixelBuffer() { return HDRStaticMetadata(pixelBuffer: pixelBuffer) }
        return player?.tracks(mediaType: .video).first { $0.isEnabled }?.formatDescription
            .flatMap(HDRStaticMetadata.init(formatDescription:))
    }

    public func stop() {
        cancelSeek()
        pollTimer?.invalidate()
        pollTimer = nil
        wantsPlay = false
        player?.delegate = nil
        embeddedSubtitle = nil
        activeSubtitleParts = []
        subtitleImageCache = [:]
        hasEmbeddedSubtitle = false
        mediaInfo = nil
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

    private func updatePolling() {
        let interval: TimeInterval?
        switch status {
        case .playing, .buffering: interval = 0.25
        case .paused: interval = 1
        default: interval = nil
        }
        guard pollTimer?.timeInterval != interval else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pollTick = 0
        guard let interval else { return }
        let ticksPerSecond = Int(1 / interval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(ticksPerSecond: ticksPerSecond) }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll(ticksPerSecond: Int) {
        guard let player, player.isReadyToPlay else { return }
        let time = player.currentPlaybackTime
        if pendingSeekPosition == nil {
            if time.isFinite, player.playbackState != .seeking, currentTime != time { currentTime = time }
            let playable = player.playableTime
            if playable.isFinite, bufferedTime != playable { bufferedTime = playable }
        }
        // 部分片源打开时还不知道画面尺寸，首帧解码后才有。
        if videoSize == .zero, player.naturalSize != .zero { videoSize = player.naturalSize }
        pollTick += 1
        if !hasLoggedHDRMetadata, pollTick % ticksPerSecond == 0, let metadata = hdrStaticMetadata {
            hasLoggedHDRMetadata = true
            Log.player.info("KSPlayer HDR 元数据：\(metadata.summary, privacy: .public)")
        }
        if pollTick % ticksPerSecond == 0, let bytes = player.dynamicInfo?.bytesRead {
            let now = CACurrentMediaTime()
            if let last = lastBytesRead, now > last.at, bytes >= last.bytes {
                let throughput = Double(bytes - last.bytes) * 8 / (now - last.at)
                if networkThroughput != throughput { networkThroughput = throughput }
            }
            lastBytesRead = (bytes, now)
        }
        if pollTick % (5 * ticksPerSecond) == 0 {
            Log.player.info("KSPlayer 供流：time=\(self.currentTime)s ahead=\(max(0, self.bufferedTime - self.currentTime))s inputMbps=\((self.networkThroughput ?? 0) / 1_000_000) status=\(String(describing: self.status), privacy: .public) dropped=\(player.dynamicInfo?.droppedVideoFrameCount ?? 0)")
        }
    }

    private func updateStatus() {
        guard let player else { return }
        if case .failed = status { return }
        let playbackState = player.playbackState
        let next: PlaybackStatus
        switch playbackState {
        case _ where pendingSeekPosition != nil:
            next = wantsPlay ? .buffering : .paused
        case .finished:
            next = .ended
        case .playing, .seeking:
            next = player.loadState == .playable && playbackState == .playing ? .playing : .buffering
        case .paused, .stopped:
            next = status == .ended ? .ended : (player.isReadyToPlay ? .paused : .loading)
        case .idle:
            next = player.isReadyToPlay ? (wantsPlay ? .buffering : .paused) : .loading
        }
        guard status != next else { return }
        let previous = status
        status = next
        updatePolling()
        Log.player.info("KSPlayer 状态：\(String(describing: previous), privacy: .public) -> \(String(describing: self.status), privacy: .public) time=\(self.currentTime)s ahead=\(max(0, self.bufferedTime - self.currentTime))s")
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
        guard player === self.player else { return }
        duration = player.duration.isFinite ? player.duration : 0
        videoSize = player.naturalSize
        attachVideoView()
        if wantsPlay { player.play() }
        if let pendingSubtitleOrdinal { selectEmbeddedSubtitle(ordinal: pendingSubtitleOrdinal) }
        updateStatus()
        let video = player.tracks(mediaType: .video).first { $0.isEnabled }
        let audio = player.tracks(mediaType: .audio).first { $0.isEnabled }
        let range: String?
        if video?.dovi?.dv_profile == 7 { range = "HDR10（Dolby Vision P7 基础层）" } else {
            range = video?.formatDescription.map(PlaybackMediaInfo.dynamicRange)
            // P5 / P8 直通时系统收到 Dolby Vision；P7 始终只解基础层。
        }
        mediaInfo = PlaybackMediaInfo(
            video: (video as? FFmpegAssetTrack)?.codecName ?? video?.formatDescription.map(PlaybackMediaInfo.codecName),
            videoParameters: video?.description,
            dynamicRange: video?.dovi?.dv_profile == 5 || video?.dovi?.dv_profile == 8 ? "Dolby Vision" : range,
            audio: audio?.description,
            audioStreamIndex: audio.map { Int($0.trackID) }
        )
        Log.player.info("KSPlayer readyToPlay size=\(Int(self.videoSize.width))x\(Int(self.videoSize.height)) codec=\(video?.description ?? "-", privacy: .public)")
    }

    public func changeLoadState(player: some MediaPlayerProtocol) {
        guard player === self.player else { return }
        updateStatus()
    }

    public func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}

    public func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}

    public func finish(player: some MediaPlayerProtocol, error: Error?) {
        guard player === self.player else { return }
        if let error {
            cancelSeek()
            Log.player.error("KSPlayer 播放失败：\(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        } else {
            let time = player.currentPlaybackTime
            if time.isFinite, currentTime != time { currentTime = time }
            status = .ended
        }
        updatePolling()
    }
}
