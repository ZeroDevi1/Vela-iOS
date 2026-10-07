import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import libmpv
import Observation
import VelaCore

/// mpv 内核（libmpv 0.37，与 KSPlayer 共用 FFmpegKit 的 FFmpeg 6.1）。用于与系统内核 / KSPlayer / VLC 横向对比测试，
/// 也是 Android 版默认内核，便于对照两端行为。
///
/// 能力范围（未实现的能力由播放器提示切换内核，不静默失效）：
/// - 直放 MKV 等任意容器；VideoToolbox 硬解（`hwdec=videotoolbox`，经 OpenGL 互通上屏）
/// - 内嵌字幕（含 ASS 特效）由 mpv / libass 直接画进画面，所以 `embeddedSubtitleText` 恒为 nil
/// - 任意 HTTP 请求头（`http-header-fields`）
/// - 不实现：画中画、VR 取帧（mpv 帧在 GPU 纹理中，取帧需另接 render API 的 SW 输出）
/// 线程：mpv 句柄线程安全；事件经唤醒回调投递到主线程处理，属性读写在主线程。渲染见 `MPVRenderView`。
@MainActor
@Observable
public final class MPVPlaybackEngine: PlaybackEngine, EmbeddedSubtitleProviding, VideoGravityAdjustable {
    public let kind: PlaybackEngineKind = .mpv
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var isMuted = false
    public private(set) var networkThroughput: Double?
    public private(set) var videoSize: CGSize = .zero
    @ObservationIgnored public var preciseSeeking = false
    public private(set) var hasEmbeddedSubtitle = false

    /// 渲染容器：mpv 的 OpenGL 视图挂在其中并铺满。
    @ObservationIgnored public let containerView = PlayerPlatformView()
    @ObservationIgnored private var handle: OpaquePointer?
    @ObservationIgnored private var renderView: MPVRenderView?
    @ObservationIgnored private var wakeup: WakeupBox?
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var fileLoaded = false
    @ObservationIgnored private var loggedReady = false
    @ObservationIgnored private var pausedForCache = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var eofReached = false

    public var surface: PlaybackSurface { .view(containerView) }

    public var preciseCurrentTime: TimeInterval {
        guard let handle else { return currentTime }
        var value = 0.0
        return mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &value) >= 0 ? value : currentTime
    }

    public init() {
        #if os(iOS)
        containerView.backgroundColor = .black
        #else
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        #endif
        createHandle()
    }

    // MARK: - 初始化

    private func createHandle() {
        guard let handle = mpv_create() else {
            status = .failed("mpv 初始化失败")
            return
        }
        // 不读用户配置、不装默认脚本与快捷键：行为只由这里的选项决定，与 Android 版 MPV 配置对齐。
        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("msg-level", "all=warn"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"), ("ytdl", "no"),
            ("load-scripts", "no"), ("idle", "yes"), ("keep-open", "yes"),
            ("vo", "libmpv"), ("hwdec", "videotoolbox"),
            ("profile", "fast"), ("video-sync", "audio"), ("framedrop", "vo"),
            ("cache", "yes"), ("demuxer-max-bytes", "150MiB"), ("demuxer-readahead-secs", "20"),
            ("sid", "no"), ("sub-auto", "no"), ("audio-display", "no"),
            ("tls-verify", "no")
        ]
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        let result = mpv_initialize(handle)
        guard result >= 0 else {
            Log.player.error("mpv 初始化失败：\(String(cString: mpv_error_string(result)), privacy: .public)")
            mpv_terminate_destroy(handle)
            status = .failed("mpv 初始化失败")
            return
        }
        self.handle = handle
        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
            ("dwidth", MPV_FORMAT_INT64), ("dheight", MPV_FORMAT_INT64), ("cache-speed", MPV_FORMAT_INT64)
        ] {
            mpv_observe_property(handle, 0, name, format)
        }
        let box = WakeupBox { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drainEvents() } }
        }
        wakeup = box
        mpv_set_wakeup_callback(handle, mpvWakeup, Unmanaged.passUnretained(box).toOpaque())

        let view = MPVRenderView(handle: handle)
        view.frame = containerView.bounds
        #if os(iOS)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.autoresizingMask = [.width, .height]
        #endif
        containerView.addSubview(view)
        renderView = view
    }

    // MARK: - 播放控制

    public func load(_ source: PlaybackSource) {
        guard let handle else { return }
        status = .loading
        currentTime = source.startTime
        duration = 0
        bufferedTime = 0
        videoSize = .zero
        networkThroughput = nil
        wantsPlay = true
        fileLoaded = false
        loggedReady = false
        eofReached = false
        activateAudioSession()

        let headers = source.httpHeaders.map { "\($0.key): \($0.value.replacingOccurrences(of: ",", with: "\\,"))" }.joined(separator: ",")
        mpv_set_property_string(handle, "http-header-fields", headers)
        if source.forwardBufferDuration > 0 {
            mpv_set_property_string(handle, "demuxer-readahead-secs", String(Int(source.forwardBufferDuration)))
        }
        mpv_set_property_string(handle, "pause", "no")
        // 起播位置与字幕用属性设置，而不是 loadfile 的逐文件选项：该参数的位置在 mpv 0.38 改变过
        // （新增了插入序号参数），当前 libmpv 为 0.37，用属性写法与两种版本都兼容。
        mpv_set_property_string(handle, "start", String(format: "%.3f", source.startTime))
        if !hasEmbeddedSubtitle { mpv_set_property_string(handle, "sid", "no") }
        command(["loadfile", source.url.absoluteString, "replace"])
    }

    public func play() {
        wantsPlay = true
        if eofReached {
            Task { await seek(to: 0) }
        }
        setProperty("pause", "no")
    }

    public func pause() {
        wantsPlay = false
        setProperty("pause", "yes")
    }

    public func seek(to seconds: TimeInterval) async {
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        currentTime = target
        command(["seek", String(format: "%.3f", target), preciseSeeking ? "absolute+exact" : "absolute+keyframes"])
    }

    public func currentFrameRate() -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &value) >= 0 && value > 0 ? value : nil
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        setProperty("speed", String(rate))
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        setProperty("mute", muted ? "yes" : "no")
    }

    /// mpv 按类型给轨道编号（从 1 开始，与文件中出现顺序一致）。
    public func selectAudioTrack(ordinal: Int) async -> Bool {
        guard trackCount(type: "audio") > 1 else { return false }
        setProperty("aid", String(ordinal + 1))
        return true
    }

    /// 选择内嵌字幕（按内嵌字幕轨出现顺序，从 0 开始）；nil 关闭。字幕由 libass 画进画面。
    public func selectEmbeddedSubtitle(ordinal: Int?) {
        hasEmbeddedSubtitle = ordinal != nil
        setProperty("sid", ordinal.map { String($0 + 1) } ?? "no")
    }

    public func embeddedSubtitleText(at time: TimeInterval) -> String? { nil }

    /// `screenshot-to-file` 同步写入（只截视频画面，不含字幕），再读回。
    public func captureFrame() async -> CGImage? {
        guard fileLoaded else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "vela-mpv-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        command(["screenshot-to-file", url.path, "video"])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public func setGravity(_ gravity: PlayerController.VideoGravity) {
        switch gravity {
        case .fit:
            setProperty("keepaspect", "yes")
            setProperty("panscan", "0")
        case .fill:
            setProperty("keepaspect", "yes")
            setProperty("panscan", "1")
        case .stretch:
            setProperty("panscan", "0")
            setProperty("keepaspect", "no")
        }
    }

    public func stop() {
        wantsPlay = false
        // 渲染上下文必须先于 mpv 句柄释放。
        renderView?.teardown()
        renderView?.removeFromSuperview()
        renderView = nil
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
        handle = nil
        wakeup = nil
        status = .idle
    }

    // MARK: - 内部

    private func setProperty(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func command(_ arguments: [String]) {
        guard let handle else { return }
        var cStrings = arguments.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        cStrings.append(nil)
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                _ = mpv_command(handle, pointer)
            }
        }
    }

    private func stringProperty(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func trackCount(type: String) -> Int {
        guard let handle else { return 0 }
        var count: Int64 = 0
        guard mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count) >= 0 else { return 0 }
        return (0..<Int(count)).filter { index in
            guard let value = mpv_get_property_string(handle, "track-list/\(index)/type") else { return false }
            defer { mpv_free(value) }
            return String(cString: value) == type
        }.count
    }

    private func drainEvents() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                    handleProperty(property)
                }
            case MPV_EVENT_FILE_LOADED:
                fileLoaded = true
                if !wantsPlay { setProperty("pause", "yes") }
            case MPV_EVENT_PLAYBACK_RESTART:
                if !loggedReady {
                    loggedReady = true
                    // 与其他内核的 readyToPlay 日志对齐，便于对比实际解码方式（hwdec-current 为 no 即软解）。
                    Log.player.info("mpv readyToPlay codec=\(self.stringProperty("video-codec") ?? "-", privacy: .public) hwdec=\(self.stringProperty("hwdec-current") ?? "-", privacy: .public) size=\(self.stringProperty("width") ?? "-", privacy: .public)x\(self.stringProperty("height") ?? "-", privacy: .public)")
                }
                fileLoaded = true
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                   end.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(end.error))
                    Log.player.error("mpv 播放失败：\(message, privacy: .public)")
                    status = .failed("mpv 无法播放：\(message)")
                }
            default:
                break
            }
        }
        updateStatus()
    }

    private func handleProperty(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        guard let data = property.data else { return }
        switch (name, property.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE): currentTime = data.load(as: Double.self)
        case ("duration", MPV_FORMAT_DOUBLE): duration = data.load(as: Double.self)
        case ("demuxer-cache-time", MPV_FORMAT_DOUBLE): bufferedTime = data.load(as: Double.self)
        case ("pause", MPV_FORMAT_FLAG): paused = data.load(as: Int32.self) != 0
        case ("paused-for-cache", MPV_FORMAT_FLAG): pausedForCache = data.load(as: Int32.self) != 0
        case ("eof-reached", MPV_FORMAT_FLAG): eofReached = data.load(as: Int32.self) != 0
        case ("dwidth", MPV_FORMAT_INT64):
            videoSize.width = CGFloat(data.load(as: Int64.self))
        case ("dheight", MPV_FORMAT_INT64):
            videoSize.height = CGFloat(data.load(as: Int64.self))
        case ("cache-speed", MPV_FORMAT_INT64):
            networkThroughput = Double(data.load(as: Int64.self)) * 8
        default:
            break
        }
    }

    private func updateStatus() {
        if case .failed = status { return }
        if eofReached {
            status = .ended
        } else if !fileLoaded {
            status = .loading
        } else if pausedForCache {
            status = .buffering
        } else {
            status = paused ? .paused : .playing
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

/// mpv 唤醒回调：在 mpv 核心线程触发。必须是文件级的非隔离函数——写成主线程隔离方法里的闭包会被推断为
/// 主线程隔离，Swift 6 的运行时隔离检查会在 mpv 线程调用时直接中断进程。
private func mpvWakeup(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<WakeupBox>.fromOpaque(context).takeUnretainedValue().fire()
}

/// mpv 唤醒回调的转发对象：回调在 mpv 内部线程触发，只做投递。
private final class WakeupBox: @unchecked Sendable {
    let fire: @Sendable () -> Void
    init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
}
