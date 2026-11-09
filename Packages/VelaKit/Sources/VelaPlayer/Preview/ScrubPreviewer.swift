import AVFoundation
import Foundation
import Observation
import VelaCore

/// 拖动进度条时的画面预览，完全在本地解码，不依赖服务器的 trickplay / BIF 预览图。
///
/// - 直放文件：`AVAssetImageGenerator` 按关键帧抽帧，开销小。
/// - HLS（服务器转码 / 转封装）：分片流无法用图像生成器，改用独立的静音 `AVPlayer` + 视频输出，
///   seek 后取一帧。调用方应提供与主播放独立的低码率流，避免两个播放器共享同一个转码会话。
///
/// 调度（与 Android 版一致）：
/// 1. 用户请求按「最新优先」处理，拖动过程中只解码最后一次请求的位置；
///    没有精确缓存时先显示最近的已缓存帧（见 `ScrubSweep.nearDistance`），解出后再替换。
/// 2. 直放文件在首次拖动后于后台由粗到细预生成整片网格（`ScrubSweep.positions`），
///    之后拖到任意位置都能立即显示一张邻近帧；用户请求随时插队，后台生成由控制器决定何时让位。
/// 3. 全屏模式（`refinesAtRest`）在手指停住后补一张高分辨率、更贴近目标时间的帧，避免放大缩略图发糊。
/// 帧按实际帧时间去重缓存，见 `ScrubFrameCache`。
@MainActor
@Observable
public final class ScrubPreviewer {
    public enum Source: Equatable, Sendable {
        /// 可随机访问的单文件（mp4 / mov 等）。
        case file(URL)
        /// HLS 等分片流。
        case stream(URL)
    }

    /// 最近一次生成的预览帧，及其对应的请求时间（秒）。
    public private(set) var image: CGImage?
    public private(set) var imageTime: TimeInterval?
    /// 是否配置了预览源；未配置（例如 MPV 直放 MKV）时界面不显示预览框。
    public private(set) var isEnabled = false

    /// 手指停住后是否补一张高清帧；全屏预览模式下由控制器打开。
    @ObservationIgnored public var refinesAtRest = false
    /// 返回 true 时后台预生成暂停（例如主播放正在缓冲或倍速播放），由控制器设置。
    @ObservationIgnored public var shouldYield: (@MainActor () -> Bool)?

    @ObservationIgnored private var source: Source?
    /// 延迟提供的预览源：只在用户第一次拖动时创建，避免每次起播都多请求一路转码。
    @ObservationIgnored private var sourceProvider: (@MainActor () async -> Source?)?
    @ObservationIgnored private var providerTask: Task<Source?, Never>?
    /// 是否允许后台预生成（例如计费网络下不允许）；只对直放文件生效。
    @ObservationIgnored private var allowsSweep = false
    @ObservationIgnored private var asset: AVURLAsset?
    /// 用户请求、网格预生成、静止细化各用一个生成器：尺寸与容差不同，且可以单独取消预生成的请求。
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var gridGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var refineGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var pendingTime: TimeInterval?
    /// 等待细化的位置；每次用户请求更新，细化完成、拖动结束或被新请求取代后清空。
    @ObservationIgnored private var restTime: TimeInterval?
    /// 待预生成的位置（已按由粗到细排好），首次拖动且知道片长后填充。
    @ObservationIgnored private var sweepQueue: [TimeInterval] = []
    @ObservationIgnored private var sweepStarted = false
    /// 预生成连续失败次数；达到 `sweepMaxFailures` 时放弃（片源不支持随机抽帧）。
    @ObservationIgnored private var sweepFailures = 0
    @ObservationIgnored private var duration: TimeInterval = 0
    /// 拖动进行中；结束后迟到的解码结果只进缓存，不再显示。
    @ObservationIgnored private var active = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var sweepRetry: Task<Void, Never>?
    @ObservationIgnored private var cache = ScrubFrameCache<CGImage>(costLimit: ScrubPreviewer.cacheCostLimit)

    /// 现场抽帧的最大宽度（像素）：小窗最宽 240pt，按 2 倍像素。
    private static let maxPixelWidth: CGFloat = 480
    /// 网格帧只在精确帧解出前临时顶上，用 1.5 倍像素换内存：96 张约 28 MB。
    private static let gridPixelWidth: CGFloat = 360
    /// 静止细化的最大宽度（像素），全屏铺满时足够清晰，单帧解码仍在几百毫秒内。
    private static let refinePixelWidth: CGFloat = 1280
    /// 帧缓存字节上限：网格约 28 MB，余下留给现场抽帧（480 像素宽约 0.5 MB / 张）。
    private static let cacheCostLimit = 48 * 1024 * 1024
    /// 直放文件的取帧容差（秒）：允许取前后最近的关键帧，精确帧需要从关键帧开始解码，远程文件上会慢一个数量级。
    private static let fileTolerance: TimeInterval = 2
    /// 静止细化的容差（秒），更贴近目标时间，代价是可能多解几帧。
    private static let refineTolerance: TimeInterval = 0.5
    /// HLS seek 容差（秒），分片约 3～6 秒，更细的粒度没有意义。
    private static let streamTolerance: TimeInterval = 3
    /// 手指停住多久后细化；短于此的停顿通常还在拖动。
    private static let restDelay: Duration = .milliseconds(250)
    /// 预生成每张之间的间隔，让出网络与解码器，保证用户请求随时能插队。
    private static let sweepGap: Duration = .milliseconds(40)
    /// 预生成让位时的轮询间隔。
    private static let yieldPoll: Duration = .milliseconds(500)
    private static let sweepMaxFailures = 4

    public init() {}

    /// 设置预览源。传 nil 关闭预览；切换条目或码流时需要重新调用。
    /// - Parameter allowsSweep: 是否允许首次拖动后在后台预生成整片网格（只对直放文件生效）。
    public func configure(_ source: Source?, allowsSweep: Bool = true) {
        reset()
        self.source = source
        sourceProvider = nil
        self.allowsSweep = allowsSweep
        isEnabled = source != nil
    }

    /// 设置延迟创建的预览源；`provider` 只在首次请求预览时调用一次。
    public func configure(allowsSweep: Bool = true, provider: @escaping @MainActor () async -> Source?) {
        reset()
        source = nil
        sourceProvider = provider
        self.allowsSweep = allowsSweep
        isEnabled = true
    }

    /// 请求某个位置的预览。可高频调用，内部只处理最新一次。
    /// - Parameter duration: 片长（秒），用于邻近帧距离与预生成取点；未知时传 0。
    public func request(time: TimeInterval, duration: TimeInterval) {
        guard source != nil || sourceProvider != nil else { return }
        let time = max(0, time)
        if duration > 0 { self.duration = duration }
        pendingTime = time
        restTime = refinesAtRest ? time : nil
        active = true
        if let cached = cache.exact(time) ?? cache.nearest(time, maxDistance: ScrubSweep.nearDistance(duration: self.duration)) {
            image = cached
            imageTime = time
        }
        // 预生成正在解码时取消它，让这次请求立即开始。
        gridGenerator?.cancelAllCGImageGeneration()
        startWorker()
    }

    /// 拖动结束：清掉当前帧（保留缓存，后台预生成继续）。
    public func clear() {
        pendingTime = nil
        restTime = nil
        active = false
        image = nil
        imageTime = nil
    }

    /// 释放解码资源与缓存。
    public func reset() {
        worker?.cancel()
        worker = nil
        sweepRetry?.cancel()
        sweepRetry = nil
        providerTask?.cancel()
        providerTask = nil
        for generator in [generator, gridGenerator, refineGenerator] { generator?.cancelAllCGImageGeneration() }
        generator = nil
        gridGenerator = nil
        refineGenerator = nil
        asset = nil
        streamPlayer?.pause()
        streamPlayer?.replaceCurrentItem(with: nil)
        streamPlayer = nil
        cache.removeAll()
        sweepQueue = []
        sweepStarted = false
        sweepFailures = 0
        duration = 0
        clear()
    }

    // MARK: - 调度

    private func startWorker() {
        guard worker == nil else { return }
        sweepRetry?.cancel()
        sweepRetry = nil
        worker = Task { [weak self] in
            await self?.drain()
            guard !Task.isCancelled else { return }
            self?.worker = nil
        }
    }

    /// 依次处理：最新的用户请求 → 静止细化 → 后台预生成；三者都没有时退出。
    private func drain() async {
        while !Task.isCancelled {
            if let time = pendingTime {
                pendingTime = nil
                await serve(time)
                guard !Task.isCancelled else { return }
                startSweepIfNeeded()
            } else if let time = restTime {
                await refine(at: time)
            } else if !sweepQueue.isEmpty {
                if shouldYield?() == true {
                    // 让位时退出 worker，用户拖动可立即重启，不用等后台重试的间隔。
                    sweepRetry = Task { [weak self] in
                        repeat {
                            try? await Task.sleep(for: Self.yieldPoll)
                            guard !Task.isCancelled else { return }
                        } while self?.shouldYield?() == true
                        guard let self else { return }
                        self.sweepRetry = nil
                        self.startWorker()
                    }
                    return
                }
                await sweepStep()
            } else {
                return
            }
        }
    }

    private func serve(_ time: TimeInterval) async {
        if let cached = cache.exact(time) {
            publish(cached, time: time)
            return
        }
        guard let frame = await decode(at: time), !Task.isCancelled else { return }
        let stored = cache.insert(frame.image, time: time, frameTime: frame.time, cost: frame.image.cost, grid: false)
        // 解码期间用户可能已拖到别处：仍然展示这帧（比空白好），随后继续处理最新位置。
        publish(stored, time: time)
    }

    /// 手指停住 `restDelay` 后为当前位置补一张高清帧。只对直放文件；结果不进缓存（体积大且只对这一个位置有用）。
    private func refine(at time: TimeInterval) async {
        try? await Task.sleep(for: Self.restDelay)
        // 有新请求时先处理它（restTime 已被更新）；拖动结束时 restTime 已清空。
        guard restTime == time, pendingTime == nil, active, !Task.isCancelled else { return }
        restTime = nil
        guard case .file = source, let asset else { return }
        let generator = refineGenerator ?? Self.makeGenerator(asset: asset, width: Self.refinePixelWidth, tolerance: Self.refineTolerance)
        refineGenerator = generator
        guard let frame = await Self.generate(generator, at: time), !Task.isCancelled, pendingTime == nil, restTime == nil else { return }
        publish(frame.image, time: time)
    }

    /// 首次拖动后，直放文件且允许时排好整片网格的取点。
    private func startSweepIfNeeded() {
        guard !sweepStarted, allowsSweep, duration > 0, case .file = source else { return }
        sweepStarted = true
        sweepQueue = ScrubSweep.positions(duration: duration)
    }

    private func sweepStep() async {
        let time = sweepQueue.removeFirst()
        guard !cache.hasExact(time), let asset else { return }
        let generator = gridGenerator ?? Self.makeGenerator(asset: asset, width: Self.gridPixelWidth, tolerance: Self.fileTolerance)
        gridGenerator = generator
        let result = await Self.generate(generator, at: time)
        guard !Task.isCancelled else { return }
        guard let frame = result else {
            if pendingTime != nil {
                // 被用户请求取消：放回队首，稍后重试。
                sweepQueue.insert(time, at: 0)
            } else {
                sweepFailures += 1
                if sweepFailures >= Self.sweepMaxFailures { sweepQueue = [] }
            }
            return
        }
        sweepFailures = 0
        cache.insert(frame.image, time: time, frameTime: frame.time, cost: frame.image.cost, grid: true)
        try? await Task.sleep(for: Self.sweepGap)
    }

    // MARK: - 解码

    private struct Frame {
        var image: CGImage
        /// 实际解出的帧时间（秒）。
        var time: TimeInterval
    }

    private func decode(at time: TimeInterval) async -> Frame? {
        guard let source = await resolvedSource(), !Task.isCancelled else { return nil }
        switch source {
        case .file(let url):
            let asset = asset ?? AVURLAsset(url: url)
            self.asset = asset
            let generator = generator ?? Self.makeGenerator(asset: asset, width: Self.maxPixelWidth, tolerance: Self.fileTolerance)
            self.generator = generator
            return await Self.generate(generator, at: time)
        case .stream(let url):
            return await decodeStream(url: url, at: time)
        }
    }

    private func resolvedSource() async -> Source? {
        if let source { return source }
        guard let sourceProvider else { return nil }
        let task = providerTask ?? Task { await sourceProvider() }
        providerTask = task
        let resolved = await task.value
        guard !Task.isCancelled else { return nil }
        // 提供方失败时不再重试，避免拖动过程中反复请求服务器。
        self.sourceProvider = nil
        source = resolved
        if resolved == nil { isEnabled = false }
        return resolved
    }

    private static func makeGenerator(asset: AVURLAsset, width: CGFloat, tolerance: TimeInterval) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        let tolerance = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// 回调式接口：生成器留在主 actor 上，不把非 Sendable 的实例跨隔离域传递。取消或失败返回 nil。
    private static func generate(_ generator: AVAssetImageGenerator, at time: TimeInterval) async -> Frame? {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { image, actualTime, error in
                if let error, (error as NSError).code != AVError.operationCancelled.rawValue {
                    Log.player.debug("预览抽帧失败：\(error.localizedDescription, privacy: .public)")
                }
                let frameTime = actualTime.isNumeric ? actualTime.seconds : time
                continuation.resume(returning: image.map { Frame(image: $0, time: frameTime) })
            }
        }
    }

    private func decodeStream(url: URL, at time: TimeInterval) async -> Frame? {
        let player = streamPlayer ?? {
            let item = AVPlayerItem(url: url)
            // 预览播放器始终暂停，只需 seek 点附近的分片；默认前向缓冲会持续下载并让服务器继续转码，与主播放抢带宽。
            item.preferredForwardBufferDuration = 1
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            return player
        }()
        streamPlayer = player
        guard let item = player.currentItem, await waitUntilReady(item) else { return nil }
        let tolerance = CMTime(seconds: Self.streamTolerance, preferredTimescale: 600)
        let finished = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        guard finished, !Task.isCancelled else { return nil }
        let frameTime = item.currentTime().seconds
        guard let image = await VideoFrameGrabber.grab(from: item, maxPixelWidth: Self.maxPixelWidth, timeout: .seconds(4)) else { return nil }
        return Frame(image: image, time: frameTime.isFinite ? frameTime : time)
    }

    private func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<100 {
            switch item.status {
            case .readyToPlay: return true
            case .failed:
                Log.player.debug("预览流加载失败：\(item.error?.localizedDescription ?? "-", privacy: .public)")
                return false
            default:
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return false }
            }
        }
        return false
    }

    private func publish(_ frame: CGImage, time: TimeInterval) {
        guard active else { return }
        image = frame
        imageTime = time
    }
}

private extension CGImage {
    /// 位图占用的字节数，用作缓存开销。
    var cost: Int { bytesPerRow * height }
}
