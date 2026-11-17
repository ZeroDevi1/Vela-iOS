import AVFoundation
import Foundation
import Observation
import VelaCore

public struct ScrubPreviewFrameSample: Sendable {
    public let image: CGImage
    /// 图像在媒体时间轴上的实际位置，单位为秒。
    public let time: TimeInterval

    public init(image: CGImage, time: TimeInterval) {
        self.image = image
        self.time = time
    }
}

@MainActor
@Observable
public final class ScrubPreviewer {
    public enum Source: Equatable, Sendable {
        case file(URL)
        case stream(URL)
    }

    public typealias FrameProvider = @MainActor (TimeInterval) async -> ScrubPreviewFrameSample?

    public var image: CGImage? { displayedFrame?.image }
    public var imageTime: TimeInterval? { displayedFrame?.time }
    public private(set) var isEnabled = false
    private var displayedFrame: ScrubPreviewFrameSample?

    /// 全屏模式手指停住时补一张高分辨率帧。
    @ObservationIgnored public var refinesAtRest = false
    /// 主播放带宽不足时暂停后台扫片。
    @ObservationIgnored public var shouldYield: (@MainActor () -> Bool)?
    @ObservationIgnored var bufferedFrame: FrameProvider?
    @ObservationIgnored private var serverFrame: FrameProvider?
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var sourceProvider: (@MainActor () async -> Source?)?
    @ObservationIgnored private var providerTask: Task<Source?, Never>?
    @ObservationIgnored private var allowsSweep = false
    @ObservationIgnored private var asset: AVURLAsset?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var gridGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var refineGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var target: TimeInterval?
    @ObservationIgnored private var requested: TimeInterval?
    @ObservationIgnored private var lastRequest: ContinuousClock.Instant?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var dispatchTask: Task<Void, Never>?
    @ObservationIgnored private var refinement: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var sweepQueue: [TimeInterval] = []
    @ObservationIgnored private var sweepStarted = false
    @ObservationIgnored private var sweepFailures = 0
    @ObservationIgnored private var duration: TimeInterval = 0
    @ObservationIgnored private var cache = ScrubFrameCache<ScrubPreviewFrameSample>(costLimit: 48 * 1024 * 1024)

    private static let maxPixelWidth: CGFloat = 480
    private static let fileTolerance: TimeInterval = 2
    private static let streamTolerance: TimeInterval = 3
    /// 短暂连续拖动合并请求，仍允许大幅移动打断耗时的网络 seek。
    private static let minimumRequestInterval: Duration = .milliseconds(75)
    private static let retargetDistance: TimeInterval = 1
    private static let maxPlaceholderDistance: TimeInterval = 2
    private static let maxFrameDistance: TimeInterval = 5

    public init() {}

    public func configure(_ source: Source?, allowsSweep: Bool = true, serverFrame: FrameProvider? = nil) {
        reset()
        self.source = source
        self.allowsSweep = allowsSweep
        self.serverFrame = serverFrame
        isEnabled = source != nil || serverFrame != nil || bufferedFrame != nil
    }

    /// 需要转码时在首次实际抽帧前解析预览流。
    public func configure(allowsSweep: Bool = true, serverFrame: FrameProvider? = nil,
                          provider: @escaping @MainActor () async -> Source?) {
        configure(nil, allowsSweep: allowsSweep, serverFrame: serverFrame)
        sourceProvider = provider
        isEnabled = true
    }

    public func request(time: TimeInterval, duration: TimeInterval) {
        guard isEnabled, time.isFinite else { return }
        let time = max(0, time)
        if duration.isFinite, duration > 0 { self.duration = duration }
        target = time

        if let cached = cache.nearest(time, maxDistance: Self.maxPlaceholderDistance) {
            publish(cached)
        }
        if let displayedFrame, abs(displayedFrame.time - time) > Self.maxFrameDistance {
            self.displayedFrame = nil
        }
        stopSweep()
        scheduleRequest()
        scheduleRefinement(at: time)
    }

    public func clear() {
        target = nil
        displayedFrame = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        cancelRequest()
        cancelRefinement()
        lastRequest = nil
        startSweep()
    }

    public func reset() {
        stopSweep()
        sweepQueue.removeAll()
        clear()
        providerTask?.cancel()
        providerTask = nil
        source = nil
        sourceProvider = nil
        serverFrame = nil
        isEnabled = false
        generator = nil
        gridGenerator = nil
        refineGenerator = nil
        asset = nil
        streamPlayer?.pause()
        streamPlayer?.replaceCurrentItem(with: nil)
        streamPlayer = nil
        cache.removeAll()
        sweepStarted = false
        sweepFailures = 0
        duration = 0
    }

    private func scheduleRequest() {
        guard let target, dispatchTask == nil else { return }
        if let requested, abs(requested - target) < Self.retargetDistance { return }
        if let lastRequest, ContinuousClock.now < lastRequest + Self.minimumRequestInterval {
            dispatchTask = Task { [weak self] in
                try? await ContinuousClock().sleep(until: lastRequest + Self.minimumRequestInterval)
                guard !Task.isCancelled, let self else { return }
                dispatchTask = nil
                scheduleRequest()
            }
            return
        }

        cancelRequest()
        if let cached = cache.exact(target, maxDistance: Self.maxFrameDistance) {
            publish(cached)
            return
        }

        requested = target
        lastRequest = .now
        requestTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let frame = await decode(at: target)
            guard !Task.isCancelled else { return }
            if let frame, isUsable(frame, at: target) {
                let stored = cache.insert(frame, time: target, frameTime: frame.time, cost: frame.image.cost, grid: false)
                if let current = self.target, abs(current - target) < Self.retargetDistance { publish(stored) }
            }
            requestTask = nil
            requested = nil
            if let current = self.target, current != target, displayedFrame == nil || abs(current - target) >= Self.retargetDistance {
                scheduleRequest()
            }
        }
    }

    private func cancelRequest() {
        guard requestTask != nil else { return }
        requestTask?.cancel()
        requestTask = nil
        requested = nil
        generator?.cancelAllCGImageGeneration()
        streamPlayer?.currentItem?.cancelPendingSeeks()
    }

    private func scheduleRefinement(at time: TimeInterval) {
        cancelRefinement()
        guard refinesAtRest, case .file = source else { return }
        refinement = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await requestTask?.value
            guard !Task.isCancelled, let asset else { return }
            let generator = refineGenerator ?? Self.makeGenerator(asset: asset, width: 1280, tolerance: 0.5)
            refineGenerator = generator
            guard let frame = await Self.generate(generator, at: time), !Task.isCancelled else { return }
            publish(frame)
        }
    }

    private func cancelRefinement() {
        refinement?.cancel()
        refinement = nil
        refineGenerator?.cancelAllCGImageGeneration()
    }

    private func startSweep() {
        guard allowsSweep, duration > 0, asset != nil, case .file = source, sweepTask == nil else { return }
        if !sweepStarted {
            sweepStarted = true
            sweepQueue = ScrubSweep.positions(duration: duration)
        }
        guard !sweepQueue.isEmpty else { return }
        sweepTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled, let self, let time = sweepQueue.first, let asset {
                if shouldYield?() == true {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                if !cache.hasExact(time) {
                    let generator = gridGenerator ?? Self.makeGenerator(asset: asset, width: 360, tolerance: Self.fileTolerance)
                    gridGenerator = generator
                    let frame = await Self.generate(generator, at: time)
                    guard !Task.isCancelled else { return }
                    if let frame, isUsable(frame, at: time) {
                        cache.insert(frame, time: time, frameTime: frame.time, cost: frame.image.cost, grid: true)
                        sweepFailures = 0
                    } else {
                        sweepFailures += 1
                        if sweepFailures >= 4 { sweepQueue.removeAll(); break }
                    }
                }
                sweepQueue.removeFirst()
                try? await Task.sleep(for: .milliseconds(40))
            }
            if !Task.isCancelled { self?.sweepTask = nil }
        }
    }

    private func stopSweep() {
        sweepTask?.cancel()
        sweepTask = nil
        gridGenerator?.cancelAllCGImageGeneration()
    }

    private func decode(at time: TimeInterval) async -> ScrubPreviewFrameSample? {
        if let frame = await bufferedFrame?(time), isUsable(frame, at: time) { return frame }
        guard !Task.isCancelled else { return nil }
        if let frame = await serverFrame?(time), isUsable(frame, at: time) { return frame }
        guard !Task.isCancelled, let source = await resolvedSource(), !Task.isCancelled else { return nil }
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
        providerTask = nil
        self.sourceProvider = nil
        source = resolved
        if resolved == nil, bufferedFrame == nil, serverFrame == nil { isEnabled = false }
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

    private static func generate(_ generator: AVAssetImageGenerator, at time: TimeInterval) async -> ScrubPreviewFrameSample? {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { image, actualTime, _ in
                let frame = image.flatMap { actualTime.isNumeric ? ScrubPreviewFrameSample(image: $0, time: actualTime.seconds) : nil }
                continuation.resume(returning: frame)
            }
        }
    }

    private func decodeStream(url: URL, at time: TimeInterval) async -> ScrubPreviewFrameSample? {
        let player = streamPlayer ?? {
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            return player
        }()
        streamPlayer = player
        guard let item = player.currentItem, await waitUntilReady(item), !Task.isCancelled else { return nil }
        let tolerance = CMTime(seconds: Self.streamTolerance, preferredTimescale: 600)
        return await VideoFrameGrabber.grabSample(from: item, maxPixelWidth: Self.maxPixelWidth, timeout: .seconds(4), prepare: {
            await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        })
    }

    private func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<100 where !Task.isCancelled {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return false
    }

    private func isUsable(_ frame: ScrubPreviewFrameSample, at time: TimeInterval) -> Bool {
        frame.time.isFinite && abs(frame.time - time) <= Self.maxFrameDistance
    }

    private func publish(_ frame: ScrubPreviewFrameSample) {
        guard let target, isUsable(frame, at: target) else { return }
        if let displayedFrame, abs(displayedFrame.time - target) < abs(frame.time - target) { return }
        displayedFrame = frame
    }
}

private extension CGImage {
    var cost: Int { bytesPerRow * height }
}
