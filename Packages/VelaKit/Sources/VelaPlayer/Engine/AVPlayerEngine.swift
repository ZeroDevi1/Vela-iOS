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
public final class AVPlayerEngine: PlaybackEngine, VideoDecodeDiagnosing, MultichannelSpatializationConfigurable, ManifestSubtitleSelecting, PlaybackMediaInfoProviding {
    @MainActor
    private final class DeferredSeek {
        let target: CMTime
        var preparation: AVPlayerSeekPreparation?
        var inPlaceBufferDuration: TimeInterval?
        var reachedEnd = false
        var wantsPlay: Bool
        var seekFinished: Bool?
        var prerollResult: Bool?

        init(target: CMTime, wantsPlay: Bool) {
            self.target = target
            self.wantsPlay = wantsPlay
        }

        func discardPreparation() {
            preparation?.cancel()
            preparation = nil
        }
    }

    public let kind: PlaybackEngineKind = .avFoundation
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var bufferedTime: TimeInterval = 0
    public private(set) var pendingSeekPosition: TimeInterval?
    public private(set) var rate: Float = 1
    public private(set) var isMuted = false
    public private(set) var networkThroughput: Double?
    @ObservationIgnored public var preciseSeeking = false
    /// 多声道音频交给系统空间音频处理；false 时只允许单声道 / 立体声空间化（下次加载生效）。
    @ObservationIgnored public var allowsMultichannelSpatialization = true
    /// 访问日志读取有开销：每 4 次进度回调（约 1 秒）读一次。
    @ObservationIgnored private var throughputTick = 0
    public private(set) var videoSize: CGSize = .zero
    public private(set) var mediaInfo: PlaybackMediaInfo?
    /// 有视频轨、已播放数秒却始终没有画面（只有声音）：系统解码器打不开该视频，常见于超过本机硬解上限的分辨率
    /// （如 8192 宽的 8K VR）或 MP4 中 `hev1` 标签的 HEVC。界面据此提示并提供改用 KSPlayer / 服务器缩放转码。
    public private(set) var videoDecodeIssue: String?
    /// 本条目起播位置，用于判断「已播放数秒」。
    @ObservationIgnored private var loadedAt: TimeInterval = 0

    public private(set) var player = AVPlayer()
    @ObservationIgnored var canReplacePresentationPlayer: (@MainActor () -> Bool)?
    @ObservationIgnored var replacePresentationPlayer: (@MainActor (AVPlayer) -> Void)?
    @ObservationIgnored private var deferredSeek: DeferredSeek?
    @ObservationIgnored private var allowsSeekPreloading = false
    @ObservationIgnored private var isNetworkSource = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    /// 随当前 AVPlayerItem 替换而重建。
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// 用户选择的倍速；AVPlayer 暂停时 rate 为 0，需要单独记住。
    @ObservationIgnored private var preferredRate: Float = 1

    public var surface: PlaybackSurface { .avPlayer(player) }

    public var preciseCurrentTime: TimeInterval {
        if deferredSeek?.inPlaceBufferDuration != nil { return currentTime }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : currentTime
    }

    /// 等待中的连续缓冲从当前条目实时读取，暂停推进时的进度回调不会更新 bufferedTime。
    public var isWaitingWithBufferedVideo: Bool {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, deferredSeek == nil,
              !player.isExternalPlaybackActive,
              let item = player.currentItem, item.status == .readyToPlay, !item.isPlaybackBufferEmpty,
              item.tracks.contains(where: { $0.isEnabled && $0.assetTrack?.mediaType == .video }) else { return false }
        let time = player.currentTime()
        guard let end = Self.bufferEnd(in: item, at: time) else { return false }
        return end - time.seconds >= max(3, Double(rate) * 3)
    }

    private let forMusic: Bool

    public init(forMusic: Bool = false) {
        self.forMusic = forMusic
        preciseSeeking = forMusic
        // 由系统预估缓冲是否跟得上再起播 / 恢复，避免高码率片源在带宽不足时播一下卡一下。
        player.automaticallyWaitsToMinimizeStalling = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        #if os(iOS)
        player.allowsExternalPlayback = true
        #endif
        observePlayer()
    }

    public func load(_ source: PlaybackSource) {
        load(source, asset: nil)
    }

    public func load(_ source: PlaybackSource, asset preparedAsset: AVURLAsset?) {
        if timeObserver == nil { observePlayer() }
        cancelDeferredSeek()
        isNetworkSource = SeekBufferPolicy.isNetworkSource(source.url)
        allowsSeekPreloading = source.allowsSeekPreloading && isNetworkSource
        status = .loading
        duration = 0
        bufferedTime = 0
        networkThroughput = nil
        throughputTick = 0
        mediaInfo = nil
        videoDecodeIssue = nil
        loadedAt = source.startTime
        // 时间回调要等开始播放才更新；起播即失败时换内核 / 重试要从这里取位置，不能沿用上一条目的时间或 0。
        currentTime = source.startTime
        activateAudioSession()
        var options: [String: Any] = [:]
        if !source.httpHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = source.httpHeaders
        }
        if let mimeType = source.mimeType {
            options[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        let asset = preparedAsset ?? AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = allowsMultichannelSpatialization ? .monoStereoAndMultichannel : .monoAndStereo
        // 预缓冲时长（秒）；0 表示由系统按网络情况决定。高码率片源（如 8K VR）可在设置中调大以减少卡顿。
        item.preferredForwardBufferDuration = source.forwardBufferDuration
        observeItem(item)
        player.replaceCurrentItem(with: item)
        if source.startTime > 0 {
            // 普通续播允许小幅靠近关键帧，减少起播时的额外解码；精准定位仍从记录的位置继续。
            let tolerance = preciseSeeking ? CMTime.zero : CMTime(value: 1, timescale: 2)
            player.seek(to: CMTime(seconds: source.startTime, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        play()
    }

    public func play() {
        deferredSeek?.wantsPlay = true
        if deferredSeek?.inPlaceBufferDuration != nil {
            status = .buffering
            return
        }
        if status == .ended {
            player.seek(to: .zero)
        }
        // 不用 playImmediately：它忽略缓冲是否足够，带宽不足时会频繁卡顿。
        player.defaultRate = preferredRate
        player.play()
    }

    public func pause() {
        deferredSeek?.wantsPlay = false
        player.pause()
        if deferredSeek?.inPlaceBufferDuration != nil { status = .paused }
    }

    public func seek(to seconds: TimeInterval) async {
        guard seconds.isFinite, !Task.isCancelled else { return }
        guard let item = player.currentItem else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard time.isNumeric else { return }
        let wantsPlay = deferredSeek?.wantsPlay ?? (status != .ended && player.timeControlStatus != .paused)
        cancelDeferredSeek()
        let tolerance: CMTime = preciseSeeking ? .zero : .positiveInfinity
        let preloadTolerance: CMTime = preciseSeeking ? .zero : CMTime(value: 1, timescale: 2)
        let needed = seekBufferDuration(at: target, bufferLimit: item.preferredForwardBufferDuration)
        let bufferedAhead = (Self.bufferEnd(in: item, at: time) ?? target) - target
        let seekableRanges = item.seekableTimeRanges
        let seekable = seekableRanges.contains { $0.timeRangeValue.containsTime(time) }
            || (allowsSeekPreloading && seekableRanges.isEmpty)
        let shouldBuffer = !forMusic && isNetworkSource && item.status == .readyToPlay && wantsPlay && needed > 0.1
            && seekable && bufferedAhead + 0.1 < needed
        item.cancelPendingSeeks()
        let request = DeferredSeek(target: time, wantsPlay: wantsPlay)
        deferredSeek = request
        let deadline = ContinuousClock.now + SeekBufferPolicy.maximumWait
        defer {
            if deferredSeek === request { cancelDeferredSeek() }
        }

        if shouldBuffer { pendingSeekPosition = target }
        if shouldBuffer, allowsSeekPreloading, canReplacePresentationPlayer?() == true, !player.isExternalPlaybackActive,
           player.timeControlStatus == .playing {
            await preloadBeforeSwitch(request, from: item, tolerance: preloadTolerance, deadline: deadline)
        }
        guard deferredSeek === request, !Task.isCancelled else { return }
        request.discardPreparation()
        let hasEnoughBuffer = (Self.bufferEnd(in: item, at: time) ?? target) - target + 0.1 >= needed
        if shouldBuffer, !hasEnoughBuffer, request.wantsPlay, ContinuousClock.now < deadline {
            await prepareInPlace(request, item: item, tolerance: preloadTolerance, deadline: deadline)
        } else {
            pendingSeekPosition = nil
            let seekTolerance = !forMusic && (shouldBuffer || (isNetworkSource && bufferedAhead > 0)) ? preloadTolerance : tolerance
            let finished = await seekImmediately(to: time, tolerance: seekTolerance)
            if finished, deferredSeek === request, !Task.isCancelled, request.wantsPlay,
               player.timeControlStatus == .paused { play() }
        }
    }

    private func preloadBeforeSwitch(
        _ request: DeferredSeek, from item: AVPlayerItem, tolerance: CMTime, deadline: ContinuousClock.Instant
    ) async {
        let target = request.target
        while deferredSeek === request, !Task.isCancelled, !request.reachedEnd,
              canReplacePresentationPlayer?() == true, !player.isExternalPlaybackActive {
            let time = player.currentTime()
            let reserve = (Self.bufferEnd(in: item, at: time) ?? time.seconds) - time.seconds
            guard player.timeControlStatus == .paused ||
                    (player.timeControlStatus == .playing && reserve >= 2 * Double(max(1, preferredRate))) else { return }
            let needed = seekBufferDuration(at: target.seconds, bufferLimit: item.preferredForwardBufferDuration)
            if let end = Self.bufferEnd(in: item, at: target), end - target.seconds + 0.1 >= needed { return }
            let preparation = request.preparation ?? AVPlayerSeekPreparation(
                from: item, target: target, tolerance: tolerance, rate: preferredRate, bufferDuration: needed
            )
            request.preparation = preparation
            if preparation.item.preferredForwardBufferDuration != needed { preparation.item.preferredForwardBufferDuration = needed }
            if preparation.prerollResult == false { return }
            if preparation.prerollResult == true, !preparation.item.isPlaybackBufferEmpty {
                let position = preparation.player.currentTime()
                guard position.isNumeric, position.seconds < duration,
                      abs(position.seconds - target.seconds) <= tolerance.seconds + 0.05 else { return }
                let ahead = (Self.bufferEnd(in: preparation.item, at: position) ?? position.seconds) - position.seconds
                let required = seekBufferDuration(at: position.seconds, bufferLimit: item.preferredForwardBufferDuration)
                let ready = ahead > 0 && ahead + 0.1 >= required
                if ready || ContinuousClock.now >= deadline {
                    request.preparation = nil
                    deferredSeek = nil
                    pendingSeekPosition = nil
                    promote(preparation, replacing: item, resume: request.wantsPlay, buffered: ready)
                    return
                }
            }
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func prepareInPlace(
        _ request: DeferredSeek, item: AVPlayerItem, tolerance: CMTime, deadline: ContinuousClock.Instant
    ) async {
        let player = self.player
        request.inPlaceBufferDuration = item.preferredForwardBufferDuration
        let needed = seekBufferDuration(at: request.target.seconds, bufferLimit: item.preferredForwardBufferDuration)
        item.preferredForwardBufferDuration = needed
        player.pause()
        if request.wantsPlay { status = .buffering }

        player.seek(to: request.target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak request] finished in
            Task { @MainActor in request?.seekFinished = finished }
        }
        while deferredSeek === request, request.seekFinished == nil, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard deferredSeek === request else { return }
        if request.seekFinished == nil, !Task.isCancelled {
            // 预缓冲超时后让原跳转继续，由 AVPlayer 按正常缓冲策略恢复。
            item.preferredForwardBufferDuration = request.inPlaceBufferDuration ?? 0
            deferredSeek = nil
            pendingSeekPosition = nil
            currentTime = request.target.seconds
            bufferedTime = currentTime
            if request.wantsPlay { play() }
            apply(timeControlStatus: player.timeControlStatus)
            return
        }
        var buffered = false
        if request.seekFinished == true, !Task.isCancelled, request.wantsPlay, player.status == .readyToPlay,
           item.status == .readyToPlay, ContinuousClock.now < deadline {
            player.preroll(atRate: preferredRate) { [weak request] ready in
                Task { @MainActor in request?.prerollResult = ready }
            }
            while deferredSeek === request, !Task.isCancelled, request.wantsPlay,
                  request.prerollResult != false, ContinuousClock.now < deadline {
                let position = player.currentTime()
                let ahead = (Self.bufferEnd(in: item, at: position) ?? position.seconds) - position.seconds
                let required = seekBufferDuration(at: position.seconds, bufferLimit: request.inPlaceBufferDuration ?? 0)
                if item.preferredForwardBufferDuration != required { item.preferredForwardBufferDuration = required }
                if request.prerollResult == true, !item.isPlaybackBufferEmpty, ahead > 0, ahead + 0.1 >= required {
                    buffered = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard deferredSeek === request else { return }
        cancelDeferredSeek()
        let position = player.currentTime()
        if position.isNumeric {
            currentTime = position.seconds
            bufferedTime = Self.bufferEnd(in: item, at: position) ?? currentTime
        }
        if request.wantsPlay {
            player.defaultRate = preferredRate
            if buffered { player.playImmediately(atRate: preferredRate) } else { player.play() }
        } else if status != .ended {
            status = .paused
        }
        apply(timeControlStatus: player.timeControlStatus)
    }

    private func seekBufferDuration(at position: TimeInterval, bufferLimit: TimeInterval) -> TimeInterval {
        SeekBufferPolicy.targetDuration(at: position, duration: duration, rate: preferredRate, bufferLimit: bufferLimit)
    }

    func cancelUncommittedSeek() {
        guard deferredSeek?.preparation != nil else { return }
        cancelDeferredSeek()
    }

    private func cancelDeferredSeek() {
        guard let request = deferredSeek else { return }
        deferredSeek = nil
        pendingSeekPosition = nil
        request.discardPreparation()
        player.currentItem?.cancelPendingSeeks()
        if let duration = request.inPlaceBufferDuration {
            player.cancelPendingPrerolls()
            player.currentItem?.preferredForwardBufferDuration = duration
        }
    }

    private static func bufferEnd(in item: AVPlayerItem, at time: CMTime) -> TimeInterval? {
        let end = item.loadedTimeRanges.lazy.map(\.timeRangeValue).first { $0.containsTime(time) }?.end.seconds
        return end.flatMap { $0.isFinite ? $0 : nil }
    }

    @discardableResult
    private func seekImmediately(to time: CMTime, tolerance: CMTime) async -> Bool {
        currentTime = time.seconds
        // 结束后用户拖回某个位置：离开 ended 状态，否则下次 play() 会被当作「重新播放」而回到开头。
        if status == .ended && (duration <= 0 || time.seconds < duration - 0.5) {
            status = .paused
        }
        return await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func promote(_ preparation: AVPlayerSeekPreparation, replacing item: AVPlayerItem, resume: Bool, buffered: Bool) {
        let previous = player
        let prepared = preparation.player
        prepared.isMuted = isMuted
        prepared.volume = previous.volume
        prepared.defaultRate = preferredRate
        prepared.allowsExternalPlayback = previous.allowsExternalPlayback
        preparation.item.preferredForwardBufferDuration = item.preferredForwardBufferDuration
        previous.pause()
        removePlayerObservers()
        player = prepared
        observeItem(preparation.item, isNewSource: false)
        observePlayer()
        let time = prepared.currentTime()
        currentTime = time.seconds
        bufferedTime = Self.bufferEnd(in: preparation.item, at: time) ?? currentTime
        replacePresentationPlayer?(prepared)
        if resume {
            if buffered { prepared.playImmediately(atRate: preferredRate) } else { prepared.play() }
        }
        apply(timeControlStatus: prepared.timeControlStatus)
        previous.replaceCurrentItem(with: nil)
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
        guard let current = player.currentItem, current.asset === item.asset else { return false }
        current.select(group.options[ordinal], in: group)
        deferredSeek?.discardPreparation()
        return true
    }

    /// 字幕由应用绘制：码流自带的字幕轨（服务器 HLS 字幕组、MP4 内的文本轨）不让系统按辅助功能偏好自动选中，否则画面上会出现两份字幕。
    private func deselectAutomaticSubtitles(of item: AVPlayerItem) {
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  item.currentMediaSelection.selectedMediaOption(in: group) != nil else { return }
            item.select(nil, in: group)
            if self?.player.currentItem === item { self?.deferredSeek?.discardPreparation() }
        }
    }

    public func selectManifestSubtitle(ordinal: Int?, name: String?) async -> Bool {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return ordinal == nil }
        guard let current = player.currentItem, current.asset === item.asset else { return false }
        guard let ordinal else {
            current.select(nil, in: group)
            deferredSeek?.discardPreparation()
            return true
        }
        let options = group.options
        let byName = name.flatMap { name in options.filter { $0.displayName == name } }
        let option = byName?.count == 1 ? byName?.first : (options.indices.contains(ordinal) ? options[ordinal] : nil)
        guard let option else { return false }
        current.select(option, in: group)
        deferredSeek?.discardPreparation()
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
            if forMusic {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            } else {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            }
            try session.setActive(true)
        } catch {
            Log.player.error("音频会话配置失败：\(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    public func stop() {
        cancelDeferredSeek()
        player.pause()
        removePlayerObservers()
        itemObservations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        mediaInfo = nil
        status = .idle
    }

    // MARK: - 观察

    private func removePlayerObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.removeAll()
    }

    private func observePlayer() {
        let player = self.player
        // 0.25 秒刷新足够驱动进度条；更高频率只会增加主线程负担。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player,
                      let item = player.currentItem, item.status == .readyToPlay,
                      self.deferredSeek?.inPlaceBufferDuration == nil else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                if self.currentTime != seconds { self.currentTime = seconds }
                // 拖动或 HLS 切换后可能存在不连续的缓冲，只有包含当前位置的区间可供连续播放。
                let buffered = Self.bufferEnd(in: item, at: time) ?? seconds
                if self.bufferedTime != buffered { self.bufferedTime = buffered }
                self.throughputTick += 1
                if self.throughputTick % 4 == 0,
                   let observed = item.accessLog()?.events.last?.observedBitrate,
                   observed > 0, self.networkThroughput != observed {
                    self.networkThroughput = observed
                }
                if self.throughputTick % 8 == 0 { self.checkVideoDecoding() }
                if self.throughputTick % 20 == 0 {
                    Log.player.info("AVPlayer 供流：time=\(self.currentTime)s ahead=\(max(0, self.bufferedTime - self.currentTime))s inputMbps=\((self.networkThroughput ?? 0) / 1_000_000) status=\(String(describing: self.status), privacy: .public)")
                }
            }
        }
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.player === player, player.currentItem != nil else { return }
                self.apply(timeControlStatus: player.timeControlStatus)
            }
        })
    }

    private func observeItem(_ item: AVPlayerItem, isNewSource: Bool = true) {
        videoSize = item.presentationSize
        itemObservations = [item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.videoSize != size else { return }
                self.videoSize = size
            }
        }, item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.duration = seconds.isFinite ? seconds : 0
                    if isNewSource {
                        self.logTracks(of: item)
                        self.readMediaInfo(of: item)
                        self.deselectAutomaticSubtitles(of: item)
                    }
                case .failed:
                    self.cancelDeferredSeek()
                    let detail = self.forMusic ? "无法播放音频" : message ?? "无法播放"
                    self.status = .failed(detail)
                    Log.player.error("AVPlayerItem 失败：\(detail, privacy: .public)")
                default:
                    break
                }
            }
        }]
        if forMusic {
            itemObservations.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                guard seconds.isFinite, seconds > 0 else { return }
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    self.duration = seconds
                }
            })
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                if let seek = self.deferredSeek, self.pendingSeekPosition != nil {
                    seek.reachedEnd = true
                } else {
                    self.status = .ended
                }
            }
        }
    }

    /// 播放 5 秒后仍没有画面尺寸且存在视频轨，即判定系统解码器没有输出画面（只检查一次结果，直到下次加载）。
    private func checkVideoDecoding() {
        guard videoDecodeIssue == nil, status == .playing, currentTime - loadedAt > 5,
              let item = player.currentItem, item.presentationSize == .zero,
              let video = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }) else { return }
        videoDecodeIssue = "AVPlayer 内核无法解码该视频画面：可能超过本机硬件解码上限（如 8K）或编码标签不受支持"
        // 补充编码与尺寸，便于判断原因（异步读取轨道格式）。
        Task { [weak self] in
            guard let format = try? await video.assetTrack?.load(.formatDescriptions).first else { return }
            let dimensions = format.dimensions
            let fourCC = String(decoding: [24, 16, 8, 0].map { UInt8((format.mediaSubType.rawValue >> $0) & 0xFF) }, as: UTF8.self)
            let detail = "\(fourCC) \(dimensions.width)×\(dimensions.height)"
            Log.player.error("视频无画面：\(detail, privacy: .public)")
            guard let self, self.player.currentItem === item, self.videoDecodeIssue != nil else { return }
            self.videoDecodeIssue = "AVPlayer 内核无法解码该视频画面（\(detail)）：可能超过本机硬件解码上限（如 8K）或编码标签不受支持"
        }
    }

    /// 起播诊断：画面尺寸与轨道类型。presentationSize 为 0 说明视频轨没有被解码（只有声音）。
    private func logTracks(of item: AVPlayerItem) {
        let size = item.presentationSize
        let tracks = item.tracks.map { "\($0.assetTrack?.mediaType.rawValue ?? "?")(\($0.isEnabled ? "on" : "off"))" }
        Log.player.info("readyToPlay size=\(Int(size.width))x\(Int(size.height)) tracks=\(tracks.joined(separator: ","), privacy: .public)")
    }

    private func readMediaInfo(of item: AVPlayerItem) {
        Task { [weak self] in
            var info = PlaybackMediaInfo()
            for track in item.tracks {
                guard self?.player.currentItem === item else { return }
                guard let assetTrack = track.assetTrack,
                      assetTrack.mediaType == .video || assetTrack.mediaType == .audio,
                      let format = try? await assetTrack.load(.formatDescriptions).first else { continue }
                if assetTrack.mediaType == .video {
                    let bitrate = try? await assetTrack.load(.estimatedDataRate)
                    info.video = PlaybackMediaInfo.codecName(format)
                    let fps = try? await assetTrack.load(.nominalFrameRate)
                    info.videoParameters = [
                        fps.flatMap { $0 > 0 ? String(format: "%.3f fps", $0) : nil },
                        bitrate.flatMap { $0 > 0 ? String(format: "%.1f Mbps", $0 / 1_000_000) : nil }
                    ].compactMap { $0 }.joined(separator: " · ")
                    info.dynamicRange = PlaybackMediaInfo.dynamicRange(format)
                } else if assetTrack.mediaType == .audio {
                    let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                    info.audio = [
                        PlaybackMediaInfo.codecName(format),
                        audio.map { "\(Int($0.mSampleRate)) Hz · \($0.mChannelsPerFrame) 声道" }
                    ].compactMap { $0 }.joined(separator: " · ")
                }
            }
            guard let self, self.player.currentItem === item else { return }
            self.mediaInfo = info
            Log.player.info("实际码流：\(info.video ?? "-", privacy: .public) \(info.dynamicRange ?? "-", privacy: .public) 音频 \(info.audio ?? "-", privacy: .public)")
        }
    }

    private func apply(timeControlStatus: AVPlayer.TimeControlStatus) {
        if case .failed = status { return }
        let previous = status
        switch timeControlStatus {
        case .playing: status = .playing
        case .waitingToPlayAtSpecifiedRate: status = .buffering
        case .paused:
            if let seek = deferredSeek, seek.inPlaceBufferDuration != nil {
                status = seek.wantsPlay ? .buffering : .paused
            } else if status != .ended && status != .loading {
                status = .paused
            }
        @unknown default: break
        }
        if status != previous {
            Log.player.info("AVPlayer 状态：\(String(describing: previous), privacy: .public) -> \(String(describing: self.status), privacy: .public) time=\(self.currentTime)s reason=\(self.player.reasonForWaitingToPlay?.rawValue ?? "-", privacy: .public)")
        }
    }
}

