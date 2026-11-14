import AVFoundation
import Foundation
import Observation
import VelaCore
import VelaDesignSystem
import VelaNetwork
import VelaPlayer

struct MusicSource: Sendable {
    let client: NavidromeClient
    let capabilities: NavidromeClient.Capabilities
    let isPrivate: Bool
    let user: NavidromeUser?

    var id: String { client.accountID }
    var isAdmin: Bool { user?.adminRole == true }
    var canShare: Bool { user?.shareRole == true }
    var canDownload: Bool { user?.downloadRole == true }
    var canUseJukebox: Bool { user?.jukeboxRole == true }

    func coverKey(_ cover: String, size: Int) -> URL? {
        var key = URLComponents()
        key.scheme = "vela-music-cover"
        key.path = "/image"
        key.queryItems = [
            .init(name: "account", value: id), .init(name: "cover", value: cover),
            .init(name: "size", value: String(size)), .init(name: "private", value: isPrivate ? "1" : "0")
        ]
        return key.url
    }

    func artwork(_ cover: String, size: Int) async -> CGImage? {
        guard let key = coverKey(cover, size: size) else { return nil }
        return await ImagePipeline.shared.image(key: key, memoryOnly: isPrivate) {
            try await client.cover(cover, size: size)
        }
    }
}

/// 按实际播放时间记录历史；拖动进度、预加载和重复状态不会额外记一遍。
@MainActor
@Observable
final class MusicSession {
    enum Mode: String, CaseIterable {
        case order, loop, repeatOne, shuffle

        var title: String {
            switch self {
            case .order: "顺序播放"
            case .loop: "列表循环"
            case .repeatOne: "单曲循环"
            case .shuffle: "随机播放"
            }
        }

        var symbol: String {
            switch self {
            case .order: "arrow.right"
            case .loop: "repeat"
            case .repeatOne: "repeat.1"
            case .shuffle: "shuffle"
            }
        }
    }

    @ObservationIgnored private(set) lazy var engine = AVPlayerEngine(forMusic: true)
    private(set) var source: MusicSource?
    private(set) var queue: [NavidromeTrack] = []
    private(set) var index: Int?
    private(set) var compatible = false
    private(set) var playbackError: String?
    private(set) var mode: Mode = .order

    @ObservationIgnored private let nowPlaying = NowPlayingCenter()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var lastSample: TimeInterval?
    @ObservationIgnored private var lastReport: (state: NavidromeClient.PlaybackState, at: Date)?
    @ObservationIgnored private var lastPlaying: Bool?
    @ObservationIgnored private var remembered = false
    @ObservationIgnored private var marked = false
    @ObservationIgnored private var usedTimeline = false
    private var offset = 0
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var sourceLoad: Task<Void, Never>?
    @ObservationIgnored private var negotiatedStream = false
    @ObservationIgnored private var flacLoader: MusicFLACLoader?
    @ObservationIgnored private var progressiveFLACURL: URL?
    @ObservationIgnored private var progressiveFLACStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var stagedOriginal: URL?
    private var preparingStream = false
    private var pendingOriginalPosition: TimeInterval?
    private var requestedAutoplay = true
    private var radioURL: URL?
    var isRadio: Bool { radioURL != nil }
    private var history: [String: [NavidromeTrack]] = [:]

    var current: NavidromeTrack? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var duration: TimeInterval {
        if let duration = current?.duration, duration.isFinite, duration > 0 { return duration }
        return engine.duration > 0 ? engine.duration + Double(offset) : current?.duration ?? 0
    }
    var position: TimeInterval {
        if let pendingOriginalPosition { return pendingOriginalPosition }
        return duration > 0 ? min(duration, engine.currentTime + Double(offset)) : 0
    }
    var lyricPosition: TimeInterval {
        if let pendingOriginalPosition { return pendingOriginalPosition }
        if preparingStream { return Double(offset) }
        // 当前进度负责通知暂停时的跳转，播放时用播放器的精确时钟绘制逐字进度。
        let time = isPlaying ? engine.preciseCurrentTime : engine.currentTime
        return max(0, time + Double(offset))
    }
    var isPlaying: Bool { engine.player.rate > 0 || engine.status == .playing }
    var wantsPlayback: Bool {
        preparingStream ? requestedAutoplay : isPlaying || (engine.status == .buffering && engine.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }
    var canSeek: Bool { !isRadio && duration > 0 && (!compatible || source?.capabilities.transcodeOffset == true) }
    var canSkipNext: Bool { nextIndex(automatic: false) != nil }

    func recent(for source: MusicSource) -> [NavidromeTrack] {
        if let tracks = history[source.id] { return tracks }
        guard !source.isPrivate, let data = UserDefaults.standard.data(forKey: historyKey(source.id)),
              let tracks = try? JSONDecoder().decode([NavidromeTrack].self, from: data) else { return [] }
        return tracks
    }

    func removeHistory(_ accountID: String) {
        history[accountID] = nil
        UserDefaults.standard.removeObject(forKey: historyKey(accountID))
    }

    func start(_ tracks: [NavidromeTrack], at index: Int, source: MusicSource, position: Double = 0, radio: URL? = nil) {
        guard tracks.indices.contains(index) else { return }
        finishTrack()
        self.source = source
        radioURL = radio
        queue = tracks
        self.index = index
        attachControls()
        beginTrack(at: position)
        observeAudioSession()
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func play(at target: Int) {
        guard queue.indices.contains(target) else { return }
        finishTrack()
        index = target
        beginTrack()
    }

    func enqueue(_ track: NavidromeTrack, next: Bool) {
        guard let index, !isRadio else { return }
        queue.insert(track, at: next ? index + 1 : queue.endIndex)
        updateCommands()
    }

    func removeUpcoming(at target: Int) {
        guard let index, target > index, queue.indices.contains(target) else { return }
        queue.remove(at: target)
        updateCommands()
    }

    func next() {
        if let target = nextIndex(automatic: false) { play(at: target) }
    }

    func previous() {
        guard let index else { return }
        if position > 3 || index == 0 {
            if canSeek { seek(to: 0) }
            else { play(at: index) }
        }
        else { play(at: index - 1) }
    }

    func cycleMode() {
        let modes = Mode.allCases
        mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count]
        updateCommands()
    }

    func play() {
        guard current != nil else { return }
        requestedAutoplay = true
        if preparingStream { return }
        if playbackError != nil {
            load(compatible: compatible, at: position)
        } else if engine.status == .ended {
            beginTrack()
        } else {
            engine.play()
        }
    }

    func pause() {
        requestedAutoplay = false
        if preparingStream { return }
        engine.pause()
        if current != nil { publish(rate: 0) }
    }

    func toggle() {
        if wantsPlayback { pause() }
        else { play() }
    }

    func retryCompatible() { load(compatible: true, at: position, autoplay: playbackError != nil || wantsPlayback) }

    func retryOriginal() { load(compatible: false, at: position, autoplay: playbackError != nil || wantsPlayback) }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, canSeek else { return }
        let target = max(0, min(seconds, max(0, duration - 1)))
        lastSample = nil
        if pendingOriginalPosition != nil {
            pendingOriginalPosition = target
            return
        }
        let wasPlaying = wantsPlayback
        if compatible {
            load(compatible: true, at: target, autoplay: wasPlaying)
        } else {
            let item = engine.player.currentItem
            Task {
                await engine.seek(to: target)
                guard engine.player.currentItem === item else { return }
                self.publish(rate: self.isPlaying ? 1 : 0)
                self.sendTimeline(self.isPlaying ? .playing : .paused, at: target)
            }
        }
    }

    func stop() {
        guard source != nil else { return }
        finishTrack()
        monitor?.cancel()
        monitor = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
        resumeAfterInterruption = false
        index = nil
        queue = []
        source = nil
        radioURL = nil
        nowPlaying.deactivate()
    }

    private func nextIndex(automatic: Bool) -> Int? {
        guard let index else { return nil }
        if automatic, mode == .repeatOne { return index }
        if mode == .shuffle {
            if queue.count == 1 { return automatic ? index : nil }
            let random = Int.random(in: 0..<(queue.count - 1))
            return random < index ? random : random + 1
        }
        if index + 1 < queue.count { return index + 1 }
        return mode == .loop ? 0 : nil
    }

    private func beginTrack(at position: TimeInterval = 0) {
        listened = 0
        remembered = false
        marked = false
        usedTimeline = false
        lastSample = nil
        lastPlaying = nil
        lastReport = nil
        offset = 0
        guard let source, let current else { return }
        load(compatible: false, at: position)
        sendTimeline(.starting, at: position)
        artworkTask?.cancel()
        artworkTask = nil
        if !source.isPrivate { nowPlaying.setArtwork(nil) }
        if !source.isPrivate, let cover = current.coverArt {
            artworkTask = Task { [weak self] in
                let pixels = await source.artwork(cover, size: 650)
                guard !Task.isCancelled else { return }
                self?.nowPlaying.setArtwork(pixels)
            }
        }
    }

    private func load(compatible: Bool, at seconds: TimeInterval, autoplay: Bool = true) {
        guard let current, let source else { return }
        self.compatible = compatible
        offset = compatible && source.capabilities.transcodeOffset ? Int(max(0, seconds)) : 0
        lastSample = nil
        playbackError = nil
        sourceLoad?.cancel()
        preparingStream = false
        pendingOriginalPosition = nil
        negotiatedStream = false
        requestedAutoplay = autoplay
        if compatible, source.capabilities.supports("transcoding"), !isRadio {
            // 先静音旧流，避免等待协商时仍播放旧位置。
            engine.pause()
            preparingStream = true
            let targetOffset = offset
            sourceLoad = Task {
                let decision = try? await source.client.transcodeDecision(id: current.id, compatible: true)
                guard !Task.isCancelled else { return }
                let negotiatedURL = decision?.transcodeParams.flatMap {
                    try? source.client.transcodeURL(id: current.id, token: $0, offset: targetOffset)
                }
                preparingStream = false
                negotiatedStream = negotiatedURL != nil
                openStream(current, source: source, url: negotiatedURL, seconds: seconds, autoplay: requestedAutoplay)
            }
        } else {
            openStream(current, source: source, url: radioURL, seconds: seconds, autoplay: autoplay)
        }
    }

    private func openStream(_ track: NavidromeTrack, source: MusicSource, url: URL?, seconds: Double, autoplay: Bool) {
        do {
            let url = try url ?? source.client.streamURL(id: track.id, compatible: compatible, offset: offset)
            let isFLAC = track.suffix?.lowercased() == "flac" || track.contentType?.lowercased() == "audio/flac"
            let rawFLAC = !compatible && !isRadio && isFLAC
            let previousLoader = flacLoader
            flacLoader = nil
            progressiveFLACURL = nil
            progressiveFLACStartedAt = nil
            if rawFLAC, !url.isFileURL {
                flacLoader = MusicFLACLoader(client: source.client, url: url)
                progressiveFLACURL = url
                progressiveFLACStartedAt = .now
            }
            engine.load(PlaybackSource(url: url, title: track.title, subtitle: track.artist,
                                       startTime: compatible ? 0 : seconds,
                                       mimeType: rawFLAC ? "audio/flac" : nil,
                                       forwardBufferDuration: flacLoader == nil ? 0 : 2),
                        asset: flacLoader?.makeAsset())
            previousLoader?.cancel()
            if !url.isFileURL { removeStagedOriginal() }
            if !autoplay { engine.pause() }
            publish(rate: 0)
        } catch {
            playbackError = "无法创建串流地址"
        }
    }

    private func stageOriginalFLAC(_ url: URL, track: NavidromeTrack, source: MusicSource) {
        pendingOriginalPosition = position
        preparingStream = true
        releaseFLACLoader()
        engine.stop()
        sourceLoad = Task {
            do {
                let file = try await source.client.stageOriginalFLAC(from: url)
                guard !Task.isCancelled, let target = pendingOriginalPosition else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                stagedOriginal = file
                openStream(track, source: source, url: file, seconds: target, autoplay: requestedAutoplay)
                pendingOriginalPosition = nil
            } catch {
                guard !Task.isCancelled else { return }
                playbackError = "无法读取原始音频，请重试或使用兼容转码"
                publish(rate: 0)
            }
            preparingStream = false
        }
    }

    private func removeStagedOriginal() {
        if let stagedOriginal { try? FileManager.default.removeItem(at: stagedOriginal) }
        stagedOriginal = nil
    }

    private func releaseFLACLoader() {
        flacLoader?.cancel()
        flacLoader = nil
        progressiveFLACURL = nil
        progressiveFLACStartedAt = nil
    }

    private func finishTrack() {
        sourceLoad?.cancel()
        if usedTimeline { sendTimeline(.stopped, at: position) }
        preparingStream = false
        pendingOriginalPosition = nil
        releaseFLACLoader()
        usedTimeline = false
        lastSample = nil
        artworkTask?.cancel()
        engine.stop()
        removeStagedOriginal()
    }

    private func tick() {
        guard let track = current, let source else { return }
        guard !preparingStream else { return }
        if case .failed = engine.status {
            if let url = progressiveFLACURL {
                stageOriginalFLAC(url, track: track, source: source)
            } else if !compatible && radioURL == nil {
                load(compatible: true, at: position)
            } else if negotiatedStream {
                negotiatedStream = false
                openStream(track, source: source, url: nil, seconds: 0, autoplay: requestedAutoplay)
            } else if playbackError == nil {
                playbackError = radioURL == nil ? "无法播放此曲目，请检查网络或服务器的转码设置" : "无法播放此电台，请检查网络或串流地址"
                publish(rate: 0)
                sendTimeline(.paused, at: position)
            }
            return
        }
        if engine.player.timeControlStatus == .playing, let startedAt = progressiveFLACStartedAt, let flacLoader {
            let elapsed = startedAt.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            Log.player.info("原始 FLAC 起播：\(milliseconds, privacy: .public) ms，已读取 \(flacLoader.receivedBytes, privacy: .public) 字节")
            progressiveFLACStartedAt = nil
        }
        if engine.status == .ended {
            guard lastPlaying != false || usedTimeline else { return }
            let target = nextIndex(automatic: true)
            if let target { play(at: target) }
            else {
                sendTimeline(.stopped, at: duration)
                usedTimeline = false
                lastPlaying = false
                publish(rate: 0)
            }
            return
        }
        let state: NavidromeClient.PlaybackState = isPlaying ? .playing : .paused
        if isPlaying, radioURL == nil {
            if let lastSample {
                let delta = position - lastSample
                if delta > 0, delta <= 1.5 { listened += delta }
            }
            lastSample = position
            let threshold = duration > 0 ? min(240, max(0.5, duration / 2)) : 30
            if !remembered, listened >= min(5, threshold) {
                remembered = true
                var tracks = recent(for: source).filter { $0.id != track.id }
                tracks.insert(track, at: 0)
                tracks = Array(tracks.prefix(50))
                history[source.id] = tracks
                if !source.isPrivate, let data = try? JSONEncoder().encode(tracks) {
                    UserDefaults.standard.set(data, forKey: historyKey(source.id))
                }
            }
            if !marked, listened >= threshold {
                marked = true
                if !source.capabilities.playbackReport && !source.isPrivate {
                    report { try await source.client.scrobble(id: track.id, submission: true) }
                }
            }
        } else {
            lastSample = nil
        }
        if lastPlaying != isPlaying {
            lastPlaying = isPlaying
            publish(rate: isPlaying ? 1 : 0)
            if isPlaying || lastReport?.state == .playing { sendTimeline(state, at: position) }
        } else if isPlaying, lastReport.map({ Date.now.timeIntervalSince($0.at) >= 15 }) == true {
            sendTimeline(.playing, at: position)
        }
    }

    private func historyKey(_ accountID: String) -> String { "music.recent." + accountID }

    private func sendTimeline(_ state: NavidromeClient.PlaybackState, at position: TimeInterval) {
        guard radioURL == nil, let source, let current, source.capabilities.playbackReport, !source.isPrivate else { return }
        usedTimeline = true
        lastReport = (state, .now)
        let ignoreScrobble = state == .stopped && !marked
        report { try await source.client.report(id: current.id, position: position, state: state, ignoreScrobble: ignoreScrobble) }
    }

    private func report(_ submit: @escaping @Sendable () async throws -> Void) {
        let previous = reportTask
        // 状态写入按顺序发送；请求结果不明时不重发，避免重复计数。
        reportTask = Task {
            await previous?.value
            try? await submit()
        }
    }

    private func publish(rate: Float) {
        guard let current, source?.isPrivate != true else { return }
        updateCommands()
        nowPlaying.update(title: current.title, subtitle: current.artist, duration: duration,
                          position: position, rate: rate, isMusic: true, album: current.album)
    }

    private func updateCommands() {
        guard source?.isPrivate == false else { return }
        nowPlaying.updateMusicCommands(canSkipNext: canSkipNext, canSeek: canSeek)
    }

    private func attachControls() {
        guard source?.isPrivate != true else {
            nowPlaying.deactivate()
            return
        }
        nowPlaying.activateMusic(
            play: { [weak self] in self?.play() }, pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.toggle() }, next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() }, seek: { [weak self] in self?.seek(to: $0) }
        )
    }

    private func observeAudioSession() {
        #if os(iOS)
        guard lifecycleObservers.isEmpty else { return }
        let audio = AVAudioSession.sharedInstance()
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: audio, queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            guard context?.source == .system else { return }
            Task { @MainActor [weak self] in
                guard let self, self.current != nil else { return }
                self.resumeAfterInterruption = self.lastPlaying == true
                self.pause()
            }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification, object: audio, queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            Task { @MainActor [weak self] in
                guard let self, self.current != nil else { return }
                if self.resumeAfterInterruption && context?.recommendation == .shouldResume { self.play() }
                self.resumeAfterInterruption = false
            }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: audio, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.pause() }
        })
        #endif
    }
}
