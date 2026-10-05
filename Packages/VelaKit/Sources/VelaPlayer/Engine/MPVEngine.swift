import AVFoundation
import Foundation
import Libmpv
import Observation
import QuartzCore
import VelaCore

/// MPV 内核（libmpv，经 MPVKit）。用于系统内核无法直放的片源（MKV、ASS 特效字幕等），直接播放原文件、不经服务器转码。
///
/// 渲染：`vo=gpu-next` + Vulkan（MoltenVK）绘制到 `CAMetalLayer`；硬解走 VideoToolbox。
/// 线程：libmpv 事件在专用串行队列读取，属性变化回到主 actor 更新；所有 `mpv_*` 调用都在持有句柄期间进行，`stop()` 后句柄失效。
@MainActor
@Observable
public final class MPVEngine: PlaybackEngine {
    public let kind: PlaybackEngineKind = .mpv
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var videoSize: CGSize = .zero

    /// 渲染目标；由 `PlayerSurface` 放进视图层级。
    @ObservationIgnored public let metalLayer = CAMetalLayer()
    @ObservationIgnored private var handle: Handle?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var isBuffering = false
    @ObservationIgnored private var reachedEnd = false
    /// 文件加载完成前不能执行 `sub-add` 等命令；先排队，FILE_LOADED 后依次执行。
    @ObservationIgnored private var isFileLoaded = false
    @ObservationIgnored private var pendingCommands: [[String]] = []

    /// mpv 句柄的线程安全包装：libmpv 的 API 本身线程安全，这里只负责生命周期。
    final class Handle: @unchecked Sendable {
        let mpv: OpaquePointer
        let queue = DispatchQueue(label: "app.vela.mpv.events")
        init(_ mpv: OpaquePointer) { self.mpv = mpv }
    }

    public var surface: PlaybackSurface { .metalLayer(metalLayer) }

    public var preciseCurrentTime: TimeInterval {
        guard let handle else { return currentTime }
        var value = 0.0
        return mpv_get_property(handle.mpv, "time-pos", MPV_FORMAT_DOUBLE, &value) >= 0 ? value : currentTime
    }

    public init() {
        metalLayer.contentsScale = 2
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    // MARK: - 生命周期

    private func makeHandle() -> Handle? {
        if let handle { return handle }
        guard let mpv = mpv_create() else {
            status = .failed("无法创建 MPV 内核")
            return nil
        }
        var layer = Unmanaged.passUnretained(metalLayer).toOpaque()
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layer)
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("hwdec", "videotoolbox"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            // 字幕由 libass 渲染（含 ASS 特效）；按系统语言自动选择。
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("cache", "yes"),
            ("video-rotate", "no"),
            ("input-default-bindings", "no"),
            ("terminal", "no")
        ]
        for (name, value) in options { mpv_set_option_string(mpv, name, value) }
        mpv_request_log_messages(mpv, "warn")
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            status = .failed("MPV 内核初始化失败")
            return nil
        }
        for (name, format) in Self.observed { mpv_observe_property(mpv, 0, name, format) }
        let handle = Handle(mpv)
        let context = Unmanaged.passUnretained(handle).toOpaque()
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let handle = Unmanaged<Handle>.fromOpaque(context).takeUnretainedValue()
            handle.queue.async { MPVEngine.drainEvents(handle) }
        }, context)
        self.handle = handle
        Self.engines[ObjectIdentifier(handle)] = WeakEngine(engine: self)
        return handle
    }

    private static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("speed", MPV_FORMAT_DOUBLE),
        ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
        ("dwidth", MPV_FORMAT_INT64),
        ("dheight", MPV_FORMAT_INT64)
    ]

    public func stop() {
        guard let handle else { return }
        self.handle = nil
        Self.engines[ObjectIdentifier(handle)] = nil
        mpv_set_wakeup_callback(handle.mpv, nil, nil)
        // 销毁会等待渲染线程退出，放到后台避免卡住主线程。
        handle.queue.async { mpv_terminate_destroy(handle.mpv) }
        status = .idle
    }

    // MARK: - 播放控制

    public func load(_ source: PlaybackSource) {
        guard let handle = makeHandle() else { return }
        status = .loading
        reachedEnd = false
        isFileLoaded = false
        pendingCommands = []
        activateAudioSession()
        if !source.httpHeaders.isEmpty {
            let fields = source.httpHeaders.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            mpv_set_property_string(handle.mpv, "http-header-fields", fields)
        }
        var options = "start=\(source.startTime)"
        if source.startTime <= 0 { options = "" }
        command(["loadfile", source.url.absoluteString, "replace", "-1", options].filter { !$0.isEmpty })
        play()
    }

    public func play() {
        if reachedEnd { command(["seek", "0", "absolute"]) }
        setFlag("pause", false)
    }

    public func pause() {
        setFlag("pause", true)
    }

    public func seek(to seconds: TimeInterval) async {
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        currentTime = target
        reachedEnd = false
        if status == .ended { status = .paused }
        command(["seek", String(target), "absolute+exact"])
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        guard let handle else { return }
        var value = Double(rate)
        mpv_set_property(handle.mpv, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    public func selectAudioTrack(ordinal: Int) async -> Bool {
        guard let handle else { return false }
        // mpv 的音轨 id 从 1 开始，按出现顺序编号。
        var id = Int64(ordinal + 1)
        return mpv_set_property(handle.mpv, "aid", MPV_FORMAT_INT64, &id) >= 0
    }

    /// 加载外挂字幕（服务器提供的原始格式，ASS 保留特效）并选中；`url` 为 nil 时关闭字幕。
    public func setExternalSubtitle(_ url: URL?) {
        guard let handle else { return }
        if let url {
            commandAfterLoad(["sub-add", url.absoluteString, "select"])
        } else {
            mpv_set_property_string(handle.mpv, "sid", "no")
        }
    }

    /// 选择文件内嵌字幕（按字幕轨出现顺序，从 0 开始）。
    public func selectEmbeddedSubtitle(ordinal: Int) {
        guard let handle else { return }
        var id = Int64(ordinal + 1)
        mpv_set_property(handle.mpv, "sid", MPV_FORMAT_INT64, &id)
    }

    /// 画面比例：适应（保持比例）、填充（裁切，`panscan=1`）、拉伸（不保持比例）。
    public func setGravity(fill: Bool, stretch: Bool) {
        guard let handle else { return }
        mpv_set_property_string(handle.mpv, "keepaspect", stretch ? "no" : "yes")
        mpv_set_property_string(handle.mpv, "panscan", fill && !stretch ? "1.0" : "0.0")
    }

    /// 字幕时间偏移（秒）。
    public func setSubtitleDelay(_ seconds: TimeInterval) {
        guard let handle else { return }
        var value = seconds
        mpv_set_property(handle.mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value)
    }

    public func captureFrame() async -> CGImage? {
        guard handle != nil else { return nil }
        let file = URL.temporaryDirectory.appending(path: "vela-mpv-\(UUID().uuidString).png")
        command(["screenshot-to-file", file.path, "video"])
        // 截图异步写盘，最多等 2 秒。
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                try? FileManager.default.removeItem(at: file)
                return image
            }
        }
        return nil
    }

    private func activateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: - mpv 调用

    private func command(_ args: [String]) {
        guard let handle else { return }
        var cStrings = args.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                _ = mpv_command_async(handle.mpv, 0, pointer)
            }
        }
    }

    private func commandAfterLoad(_ args: [String]) {
        if isFileLoaded { command(args) } else { pendingCommands.append(args) }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle.mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    // MARK: - 事件

    private struct WeakEngine { weak var engine: MPVEngine? }
    /// 句柄 → 引擎；事件队列据此把属性变化送回对应引擎。
    private static var engines: [ObjectIdentifier: WeakEngine] = [:]

    private enum Change: Sendable {
        case double(String, Double)
        case flag(String, Bool)
        case int(String, Int64)
        case fileLoaded
        case endFile(error: String?)
    }

    /// 在事件队列上读取全部待处理事件，再一次性回到主 actor 应用。
    nonisolated private static func drainEvents(_ handle: Handle) {
        var changes: [Change] = []
        while true {
            guard let event = mpv_wait_event(handle.mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let data = property.data else { continue }
                let name = String(cString: property.name)
                switch property.format {
                case MPV_FORMAT_DOUBLE: changes.append(.double(name, data.load(as: Double.self)))
                case MPV_FORMAT_FLAG: changes.append(.flag(name, data.load(as: Int32.self) != 0))
                case MPV_FORMAT_INT64: changes.append(.int(name, data.load(as: Int64.self)))
                default: break
                }
            case MPV_EVENT_FILE_LOADED:
                changes.append(.fileLoaded)
            case MPV_EVENT_END_FILE:
                let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end?.reason == MPV_END_FILE_REASON_ERROR {
                    changes.append(.endFile(error: String(cString: mpv_error_string(end?.error ?? 0))))
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.player.info("mpv: \(text, privacy: .public)")
                }
            default:
                break
            }
        }
        guard !changes.isEmpty else { return }
        let key = ObjectIdentifier(handle)
        Task { @MainActor in
            engines[key]?.engine?.apply(changes)
        }
    }

    private func apply(_ changes: [Change]) {
        for change in changes {
            switch change {
            case .double("time-pos", let value): currentTime = value
            case .double("duration", let value): duration = value
            case .double("speed", let value): rate = Float(value)
            case .double("demuxer-cache-time", let value): bufferedTime = value
            case .flag("pause", let value): isPaused = value
            case .flag("paused-for-cache", let value): isBuffering = value
            case .flag("eof-reached", let value): reachedEnd = value
            case .int("dwidth", let value): videoSize.width = CGFloat(value)
            case .int("dheight", let value): videoSize.height = CGFloat(value)
            case .fileLoaded:
                isFileLoaded = true
                let pending = pendingCommands
                pendingCommands = []
                pending.forEach(command)
            case .endFile(let error): status = .failed(error ?? "MPV 播放失败")
            default: break
            }
        }
        updateStatus()
    }

    private func updateStatus() {
        if case .failed = status { return }
        if reachedEnd {
            status = .ended
        } else if duration <= 0 && currentTime <= 0 && status == .loading {
            return
        } else if isBuffering {
            status = .buffering
        } else {
            status = isPaused ? .paused : .playing
        }
    }
}
