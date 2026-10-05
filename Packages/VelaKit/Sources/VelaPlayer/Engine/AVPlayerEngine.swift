import AVFoundation
import Foundation
import Observation
import VelaCore

/// 基于 AVPlayer 的默认内核。
///
/// HDR10 / 杜比视界（Profile 5、8.x）/ HLG 由系统自动按显示能力输出，不做色彩映射；
/// 空间音频与杜比全景声在 AirPods / 支持的扬声器上由系统处理。
@MainActor
@Observable
public final class AVPlayerEngine: PlaybackEngine {
    public let kind: PlaybackEngineKind = .avFoundation
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var isMuted = false
    public private(set) var networkThroughput: Double?
    @ObservationIgnored public var preciseSeeking = false
    /// 多声道音频交给系统空间音频处理；false 时只允许单声道 / 立体声空间化（下次加载生效）。
    @ObservationIgnored public var allowsMultichannelSpatialization = true
    /// 访问日志读取有开销：每 4 次进度回调（约 1 秒）读一次。
    @ObservationIgnored private var throughputTick = 0
    public private(set) var videoSize: CGSize = .zero

    @ObservationIgnored public let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    /// 随当前 AVPlayerItem 替换而重建。
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// 用户选择的倍速；AVPlayer 暂停时 rate 为 0，需要单独记住。
    @ObservationIgnored private var preferredRate: Float = 1

    public var surface: PlaybackSurface { .avPlayer(player) }

    public var preciseCurrentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : currentTime
    }

    public init() {
        // 由系统预估缓冲是否跟得上再起播 / 恢复，避免高码率片源在带宽不足时播一下卡一下。
        player.automaticallyWaitsToMinimizeStalling = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        #if os(iOS)
        player.allowsExternalPlayback = true
        #endif
        observePlayer()
    }

    public func load(_ source: PlaybackSource) {
        status = .loading
        activateAudioSession()
        var options: [String: Any] = [:]
        if !source.httpHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = source.httpHeaders
        }
        let asset = AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = allowsMultichannelSpatialization ? .monoStereoAndMultichannel : .monoAndStereo
        // 预缓冲时长（秒）；0 表示由系统按网络情况决定。高码率片源（如 8K VR）可在设置中调大以减少卡顿。
        item.preferredForwardBufferDuration = source.forwardBufferDuration
        observeItem(item)
        player.replaceCurrentItem(with: item)
        if source.startTime > 0 {
            player.seek(to: CMTime(seconds: source.startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        play()
    }

    public func play() {
        if status == .ended {
            player.seek(to: .zero)
        }
        // 不用 playImmediately：它忽略缓冲是否足够，带宽不足时会频繁卡顿。
        player.defaultRate = preferredRate
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func seek(to seconds: TimeInterval) async {
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        currentTime = target
        // 结束后用户拖回某个位置：离开 ended 状态，否则下次 play() 会被当作「重新播放」而回到开头。
        if status == .ended && (duration <= 0 || target < duration - 0.5) {
            status = .paused
        }
        let tolerance: CMTime = preciseSeeking ? .zero : .positiveInfinity
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    public func currentFrameRate() -> Double? {
        guard let track = player.currentItem?.tracks.first(where: { $0.assetTrack?.mediaType == .video }) else { return nil }
        let rate = Double(track.currentVideoFrameRate)
        return rate > 0 ? rate : nil
    }

    public func setRate(_ rate: Float) {
        preferredRate = rate
        self.rate = rate
        if player.timeControlStatus != .paused {
            player.rate = rate
        }
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }

    public func selectAudioTrack(ordinal: Int) async -> Bool {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              group.options.count > 1,
              group.options.indices.contains(ordinal) else { return false }
        item.select(group.options[ordinal], in: group)
        return true
    }

    public func captureFrame() async -> CGImage? {
        guard let item = player.currentItem, item.status == .readyToPlay else { return nil }
        let player = player
        // 暂停时没有新帧送达输出：原地精确 seek 一次让内核重新解码当前帧。
        return await VideoFrameGrabber.grab(from: item) {
            await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 视频播放需要 `.playback` 类别：静音开关下仍出声、后台继续播放、画中画可用。
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

    public func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.removeAll()
        itemObservations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        status = .idle
    }

    // MARK: - 观察

    private func observePlayer() {
        // 0.25 秒刷新足够驱动进度条；更高频率只会增加主线程负担。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let range = self.player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
                    self.bufferedTime = range.end.seconds.isFinite ? range.end.seconds : 0
                }
                self.throughputTick += 1
                if self.throughputTick % 4 == 0,
                   let observed = self.player.currentItem?.accessLog()?.events.last?.observedBitrate,
                   observed > 0 {
                    self.networkThroughput = observed
                }
            }
        }
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let value = player.timeControlStatus
            Task { @MainActor in self?.apply(timeControlStatus: value) }
        })
    }

    private func observeItem(_ item: AVPlayerItem) {
        videoSize = .zero
        itemObservations = [item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in self?.videoSize = size }
        }, item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.duration = seconds.isFinite ? seconds : 0
                    self.logTracks(of: item)
                case .failed:
                    self.status = .failed(message ?? "无法播放")
                    Log.player.error("AVPlayerItem 失败：\(message ?? "unknown", privacy: .public)")
                default:
                    break
                }
            }
        }]
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = .ended }
        }
    }

    /// 起播诊断：画面尺寸与轨道类型。presentationSize 为 0 说明视频轨没有被解码（只有声音）。
    private func logTracks(of item: AVPlayerItem) {
        let size = item.presentationSize
        let tracks = item.tracks.map { "\($0.assetTrack?.mediaType.rawValue ?? "?")(\($0.isEnabled ? "on" : "off"))" }
        Log.player.info("readyToPlay size=\(Int(size.width))x\(Int(size.height)) tracks=\(tracks.joined(separator: ","), privacy: .public)")
    }

    private func apply(timeControlStatus: AVPlayer.TimeControlStatus) {
        if case .failed = status { return }
        switch timeControlStatus {
        case .playing: status = .playing
        case .waitingToPlayAtSpecifiedRate: status = .buffering
        case .paused: if status != .ended && status != .loading { status = .paused }
        @unknown default: break
        }
    }
}
