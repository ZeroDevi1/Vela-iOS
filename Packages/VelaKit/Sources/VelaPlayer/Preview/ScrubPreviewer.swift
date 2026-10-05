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
/// 请求按「最新优先」处理：拖动过程中只解码最后一次请求的位置，结果按时间桶缓存，来回拖动时直接命中。
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

    @ObservationIgnored private var source: Source?
    /// 延迟提供的预览源：只在用户第一次拖动时创建，避免每次起播都多请求一路转码。
    @ObservationIgnored private var sourceProvider: (@MainActor () async -> Source?)?
    @ObservationIgnored private var providerTask: Task<Source?, Never>?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var pendingTime: TimeInterval?
    /// 拖动进行中；结束后迟到的解码结果只进缓存，不再显示。
    @ObservationIgnored private var active = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var cache: [Int: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []

    /// 预览帧最大宽度（像素）。
    private static let maxPixelWidth: CGFloat = 480
    private static let cacheLimit = 120

    public init() {}

    /// 设置预览源。传 nil 关闭预览；切换条目或码流时需要重新调用。
    public func configure(_ source: Source?) {
        reset()
        self.source = source
        sourceProvider = nil
        isEnabled = source != nil
    }

    /// 设置延迟创建的预览源；`provider` 只在首次请求预览时调用一次。
    public func configure(provider: @escaping @MainActor () async -> Source?) {
        reset()
        source = nil
        sourceProvider = provider
        isEnabled = true
    }

    /// 请求某个位置的预览。可高频调用，内部只处理最新一次。
    public func request(time: TimeInterval) {
        guard source != nil || sourceProvider != nil else { return }
        pendingTime = max(0, time)
        active = true
        if let cached = cache[bucket(for: time)] {
            image = cached
            imageTime = time
        }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    /// 拖动结束：清掉当前帧（保留缓存）。
    public func clear() {
        pendingTime = nil
        active = false
        image = nil
        imageTime = nil
    }

    /// 释放解码资源与缓存。
    public func reset() {
        worker?.cancel()
        worker = nil
        providerTask?.cancel()
        providerTask = nil
        generator?.cancelAllCGImageGeneration()
        generator = nil
        streamPlayer?.pause()
        streamPlayer?.replaceCurrentItem(with: nil)
        streamPlayer = nil
        cache = [:]
        cacheOrder = []
        clear()
    }

    // MARK: - 解码

    private func drain() async {
        while let time = pendingTime, !Task.isCancelled {
            pendingTime = nil
            if let cached = cache[bucket(for: time)] {
                publish(cached, time: time)
                continue
            }
            guard let frame = await decode(at: time) else { continue }
            // 预览源在首次解码时才确定，桶大小随之确定，因此解码后再计算缓存键。
            store(frame, key: bucket(for: time))
            // 解码期间用户可能已拖到别处：仍然展示这帧（比空白好），随后继续处理最新位置。
            publish(frame, time: time)
        }
    }

    private func decode(at time: TimeInterval) async -> CGImage? {
        guard let source = await resolvedSource() else { return nil }
        switch source {
        case .file(let url):
            return await decodeFile(url: url, at: time)
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
        // 提供方失败时不再重试，避免拖动过程中反复请求服务器。
        self.sourceProvider = nil
        source = resolved
        if resolved == nil { isEnabled = false }
        return resolved
    }

    private func decodeFile(url: URL, at time: TimeInterval) async -> CGImage? {
        let generator = generator ?? {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: Self.maxPixelWidth, height: Self.maxPixelWidth)
            // 允许取最近的关键帧：精确帧需要从关键帧开始解码，远程文件上会慢一个数量级。
            let tolerance = CMTime(seconds: Double(Self.fileBucketSeconds), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            return generator
        }()
        self.generator = generator
        // 回调式接口：生成器留在主 actor 上，不把非 Sendable 的实例跨隔离域传递。
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { image, _, error in
                if let error {
                    Log.player.debug("预览抽帧失败：\(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func decodeStream(url: URL, at time: TimeInterval) async -> CGImage? {
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
        let tolerance = CMTime(seconds: Double(Self.streamBucketSeconds) / 2, preferredTimescale: 600)
        let finished = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        guard finished, !Task.isCancelled else { return nil }
        return await VideoFrameGrabber.grab(from: item, maxPixelWidth: Self.maxPixelWidth, timeout: .seconds(4))
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

    // MARK: - 缓存

    /// 时间桶（秒）：直放文件关键帧间隔通常 2～5 秒；HLS 分片约 3～6 秒，更细的粒度没有意义。
    private static let fileBucketSeconds = 2
    private static let streamBucketSeconds = 6

    private func bucket(for time: TimeInterval) -> Int {
        let size: Int
        if case .stream = source { size = Self.streamBucketSeconds } else { size = Self.fileBucketSeconds }
        return Int(time) / size
    }

    private func store(_ image: CGImage, key: Int) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = image
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func publish(_ frame: CGImage, time: TimeInterval) {
        guard active else { return }
        image = frame
        imageTime = time
    }
}
