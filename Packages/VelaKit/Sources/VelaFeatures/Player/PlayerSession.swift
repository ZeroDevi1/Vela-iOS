import Foundation
import Observation
import VelaCore
import VelaData
import VelaNetwork
import VelaPlayer

/// 播放会话：把服务器相关的流程（选流、上报、字幕、音轨、片段、下一集、正在播放）编排到与服务器无关的 `PlayerController` 上。
///
/// 生命周期与播放界面一致；切换下一集时复用同一个会话与控制器，界面不闪烁。
@MainActor
@Observable
final class PlayerSession {
    enum Phase: Equatable {
        case preparing
        case ready
        case failed(String)
    }

    /// 音轨 / 字幕选项，`index` 为服务器 `MediaStream.Index`。
    struct TrackOption: Identifiable, Hashable {
        var id: Int { index }
        var index: Int
        var title: String
        /// 图形字幕只能由服务器烧录，选择后会触发转码。
        var requiresBurnIn: Bool
    }

    let request: PlaybackRequest
    let controller = PlayerController()
    private(set) var phase: Phase = .preparing
    private(set) var item: MediaItem?
    private(set) var stream: ResolvedStream?
    private(set) var audioOptions: [TrackOption] = []
    private(set) var subtitleOptions: [TrackOption] = []
    private(set) var selectedAudioIndex: Int?
    /// nil 表示字幕关闭。
    private(set) var selectedSubtitleIndex: Int?
    /// 切换轨道 / 码流进行中，界面据此禁用重复操作。
    private(set) var isSwitchingStream = false
    private(set) var trackError: String?
    private(set) var nextEpisode: MediaItem?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var server: SavedServer?
    @ObservationIgnored private var client: MediaServerClient?
    @ObservationIgnored private var reporter: PlaybackReporter?
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    /// 自动跳过过的片段，避免用户回拖到片头后再次被强制跳过。
    @ObservationIgnored private var autoSkipped: Set<PlaybackSegment> = []
    @ObservationIgnored private var lastNowPlayingSignature = ""
    @ObservationIgnored private var closed = false
    /// 已在播放结束时发送过 Stopped；用户随后重播需要重新开始上报会话。
    @ObservationIgnored private var endedReported = false

    /// 片段数据缺失时，离结尾多少秒提示下一集。
    private static let upNextFallbackLead: TimeInterval = 30
    /// 下一集自动播放倒计时（秒）。
    private static let upNextCountdown = 10

    init(request: PlaybackRequest) {
        self.request = request
    }

    // MARK: - 生命周期

    func prepare(app: AppModel) async {
        self.app = app
        controller.gestureSettings = app.playerPreferences.gestureSettings
        controller.onPlayNext = { [weak self] in self?.playNextEpisode() }
        phase = .preparing
        do {
            switch request.target {
            case .url(let url):
                controller.load(PlaybackSource(url: url, title: request.title))
            case .item(let serverID, let itemID):
                guard let server = app.servers.servers.first(where: { $0.id == serverID }),
                      let client = app.client(forServerID: serverID) else {
                    throw PlaybackResolveError.noMediaSource
                }
                self.server = server
                self.client = client
                let item = try await client.item(id: itemID)
                try await start(item: item, options: request.options)
            }
            phase = .ready
            nowPlaying.activate(controller: controller)
            startLoop()
        } catch {
            Log.player.error("播放准备失败：\(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        loopTask?.cancel()
        subtitleTask?.cancel()
        reporter?.stop(position: controller.engine.currentTime)
        nowPlaying.deactivate()
        controller.shutdown()
    }

    // MARK: - 起播

    /// - Parameter options: 只对用户从详情页发起的第一集生效；自动连播的下一集使用默认选择。
    private func start(item: MediaItem, options: PlaybackRequest.Options = .init()) async throws {
        guard let app, let server, let client else { return }
        self.item = item
        nextEpisode = nil
        autoSkipped = []
        endedReported = false
        app.refreshCapabilities()

        let startTime = options.startFromBeginning ? 0 : resumePosition(for: item)
        let stream = try await app.playbackResolver.resolve(
            item: item, server: server, client: client,
            capabilities: app.capabilities,
            mediaSourceID: options.mediaSourceID,
            startTime: startTime,
            audioStreamIndex: options.audioStreamIndex
        )
        apply(stream: stream, item: item, startTime: startTime, resetMetadata: true)
        configureTracks(for: stream, preferredSubtitle: options.subtitleStreamIndex)
        nowPlaying.loadArtwork(from: app.imageURL(for: item, kind: .primary, maxWidth: 600))

        // 片段与下一集不阻塞起播。
        Task { [weak self] in
            guard let self else { return }
            self.controller.segments = await PlaybackSegmentProvider().segments(for: item, client: client)
        }
        if item.kind == .episode, let seriesID = item.seriesID {
            Task { [weak self] in
                guard let episodes = try? await client.episodes(seriesID: seriesID),
                      let index = episodes.firstIndex(where: { $0.id == item.id }),
                      episodes.indices.contains(index + 1) else { return }
                self?.nextEpisode = episodes[index + 1]
            }
        }
    }

    /// 已看完（≥ 95%）的条目从头播放，其余从上次位置继续。
    private func resumePosition(for item: MediaItem) -> TimeInterval {
        guard let ticks = item.playbackPositionTicks, ticks > 0 else { return 0 }
        if let fraction = item.playedFraction, fraction >= 0.95 { return 0 }
        return Ticks.seconds(ticks)
    }

    private func apply(stream: ResolvedStream, item: MediaItem, startTime: TimeInterval, resetMetadata: Bool) {
        self.stream = stream
        Log.player.info("播放方式：\(stream.method.rawValue, privacy: .public) \(Self.redacted(stream.url), privacy: .public)")
        let video = stream.mediaSource.videoStream
        Log.player.info("视频流：\(video?.codec ?? "-", privacy: .public) tag=\(video?.codecTag ?? "-", privacy: .public) range=\(video?.videoRangeType ?? "-", privacy: .public) depth=\(video?.bitDepth ?? 0) container=\(stream.mediaSource.container ?? "-", privacy: .public)")
        let vrLayout = VRLayoutParser.parse(
            mediaSourcePath: stream.mediaSource.path,
            itemName: item.name,
            mediaSourceName: stream.mediaSource.name,
            videoWidth: video?.width,
            videoHeight: video?.height
        )
        controller.load(
            PlaybackSource(
                url: stream.url,
                title: item.seriesName ?? item.name,
                subtitle: item.episodeLabel.map { "\($0) · \(item.name)" },
                startTime: startTime,
                vrLayout: vrLayout
            ),
            resetMetadata: resetMetadata
        )

        guard let client else { return }
        let reporter = PlaybackReporter(
            client: client,
            state: PlaybackReportState(
                itemID: item.id,
                mediaSourceID: stream.mediaSource.id,
                playSessionID: stream.playSessionID,
                position: startTime,
                isPaused: false,
                playMethod: stream.reportPlayMethod,
                audioStreamIndex: stream.audioStreamIndex ?? stream.mediaSource.defaultAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleIndex
            ),
            isTranscoding: stream.method == .transcode
        )
        reporter.start()
        self.reporter = reporter
    }

    /// 去掉鉴权参数后的地址，只用于日志排查。
    private static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "-" }
        components.queryItems = components.queryItems?.map { item in
            ["api_key", "apikey", "x-emby-token"].contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "***") : item
        }
        return components.string ?? "-"
    }

    /// 内核报错后从当前位置重新选流重试（服务器转码进程可能已被回收）。
    func retryAfterFailure() {
        guard stream != nil else {
            if let app { Task { await prepare(app: app) } }
            return
        }
        Task { await reloadStream(audioStreamIndex: selectedAudioIndex, burnSubtitleIndex: stream?.burnedSubtitleIndex) }
    }

    // MARK: - 音轨 / 字幕

    /// - Parameter preferredSubtitle: 详情页选择的字幕；-1 关闭，nil 使用服务器默认。
    private func configureTracks(for stream: ResolvedStream, preferredSubtitle: Int? = nil) {
        let source = stream.mediaSource
        audioOptions = source.audioStreams.map {
            TrackOption(index: $0.index, title: Self.title(for: $0), requiresBurnIn: false)
        }
        subtitleOptions = source.subtitleStreams.map {
            TrackOption(index: $0.index, title: Self.title(for: $0), requiresBurnIn: !$0.isTextSubtitle)
        }
        selectedAudioIndex = stream.audioStreamIndex ?? source.defaultAudioStreamIndex ?? audioOptions.first?.index

        if let preferredSubtitle {
            // 用户显式选择：图形字幕也照办（会触发烧录转码）。
            selectSubtitle(preferredSubtitle >= 0 ? preferredSubtitle : nil)
            return
        }
        // 默认字幕遵循服务器按用户语言偏好给出的结果；图形字幕默认不开启，避免一起播就触发转码。
        if let index = source.defaultSubtitleStreamIndex, index >= 0,
           let option = subtitleOptions.first(where: { $0.index == index }), !option.requiresBurnIn {
            selectSubtitle(index)
        } else {
            selectedSubtitleIndex = nil
        }
    }

    private static func title(for stream: MediaStreamInfo) -> String {
        var title = stream.displayTitle ?? stream.language ?? "轨道 \(stream.index)"
        if stream.isExternal == true { title += "（外挂）" }
        return title
    }

    func selectAudio(_ index: Int) {
        guard index != selectedAudioIndex, let stream, !isSwitchingStream else { return }
        trackError = nil
        Task {
            // 直放的多音轨文件在本地切换，不经服务器；转码流只含一条音轨，必须让服务器重新出流。
            if stream.method == .directPlay,
               let ordinal = stream.mediaSource.audioStreams.firstIndex(where: { $0.index == index }),
               await controller.engine.selectAudioTrack(ordinal: ordinal) {
                selectedAudioIndex = index
                reporter?.flush(position: controller.engine.currentTime, audioStreamIndex: index, subtitleStreamIndex: selectedSubtitleIndex)
                return
            }
            await reloadStream(audioStreamIndex: index, burnSubtitleIndex: stream.burnedSubtitleIndex)
            if trackError == nil { selectedAudioIndex = index }
        }
    }

    /// - Parameter index: nil 关闭字幕。
    func selectSubtitle(_ index: Int?) {
        guard let stream, let client, let item else { return }
        trackError = nil
        subtitleTask?.cancel()
        selectedSubtitleIndex = index
        let option = index.flatMap { i in subtitleOptions.first { $0.index == i } }

        if let option, option.requiresBurnIn {
            controller.subtitleTrack = nil
            guard stream.burnedSubtitleIndex != option.index else { return }
            Task { await reloadStream(audioStreamIndex: selectedAudioIndex, burnSubtitleIndex: option.index) }
            return
        }

        // 从烧录字幕切走时需要恢复无字幕的码流（通常重新回到直放）。
        if stream.burnedSubtitleIndex != nil {
            Task { await reloadStream(audioStreamIndex: selectedAudioIndex, burnSubtitleIndex: nil) }
        }
        guard let index else {
            controller.subtitleTrack = nil
            reporter?.flush(position: controller.engine.currentTime, audioStreamIndex: selectedAudioIndex, subtitleStreamIndex: nil)
            return
        }
        let mediaSourceID = stream.mediaSource.id
        subtitleTask = Task {
            do {
                let vtt = try await client.subtitleWebVTT(itemID: item.id, mediaSourceID: mediaSourceID, streamIndex: index)
                guard !Task.isCancelled, selectedSubtitleIndex == index else { return }
                var track = SubtitleTrack(cues: WebVTTParser.parse(vtt))
                track.delay = controller.subtitleTrack?.delay ?? 0
                controller.subtitleTrack = track
                reporter?.flush(position: controller.engine.currentTime, audioStreamIndex: selectedAudioIndex, subtitleStreamIndex: index)
            } catch {
                guard !Task.isCancelled else { return }
                trackError = "字幕加载失败：\(error.localizedDescription)"
                selectedSubtitleIndex = nil
            }
        }
    }

    func adjustSubtitleDelay(by seconds: TimeInterval) {
        controller.subtitleTrack?.delay += seconds
    }

    /// 在当前位置重新向服务器请求码流（切换音轨 / 烧录字幕）。
    private func reloadStream(audioStreamIndex: Int?, burnSubtitleIndex: Int?) async {
        guard let app, let server, let client, let item, let stream else { return }
        isSwitchingStream = true
        defer { isSwitchingStream = false }
        let position = controller.engine.currentTime
        do {
            let newStream = try await app.playbackResolver.resolve(
                item: item, server: server, client: client,
                capabilities: app.capabilities,
                mediaSourceID: stream.mediaSource.id,
                startTime: position,
                audioStreamIndex: audioStreamIndex,
                burnSubtitleIndex: burnSubtitleIndex
            )
            reporter?.stop(position: position)
            apply(stream: newStream, item: item, startTime: position, resetMetadata: false)
        } catch {
            trackError = "切换失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 下一集

    private func playNextEpisode() {
        guard let next = nextEpisode else { return }
        reporter?.stop(position: controller.engine.currentTime)
        reporter = nil
        Task {
            phase = .preparing
            do {
                // 列表接口的条目不含章节，取一次完整详情。
                let full = (try? await client?.item(id: next.id)) ?? next
                try await start(item: full)
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 播放循环

    /// 每秒一次：上报心跳、自动跳过片头、弹出下一集、同步「正在播放」。
    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        let engine = controller.engine
        guard phase == .ready, engine.status != .loading else { return }
        let position = engine.currentTime
        let isPaused = !controller.isPlaying

        // 播放到结尾立即发送 Stopped（位置 = 片长），服务器据此标记已看，不必等用户关闭播放器。
        if engine.status == .ended, !endedReported {
            endedReported = true
            reporter?.stop(position: engine.duration > 0 ? engine.duration : position)
        } else if engine.status != .ended, endedReported, controller.isPlaying {
            // 结束后又开始播放（重播 / 拖回前面）：开启新的上报会话。
            endedReported = false
            restartReporting(at: position)
        } else {
            reporter?.tick(position: position, isPaused: isPaused)
        }

        if let app, app.playerPreferences.autoSkipIntro,
           let segment = controller.activeSkippableSegment, segment.kind == .intro,
           !autoSkipped.contains(segment) {
            autoSkipped.insert(segment)
            controller.skip(segment)
        }

        if let next = nextEpisode, shouldPresentUpNext(position: position, duration: engine.duration, ended: engine.status == .ended) {
            controller.presentUpNext(
                .init(
                    title: next.episodeLabel.map { "\($0) · \(next.name)" } ?? next.name,
                    subtitle: next.seriesName,
                    imageURL: app?.imageURL(for: next, kind: .primary, maxWidth: 480),
                    countdown: nil
                ),
                autoplayAfter: app?.playerPreferences.autoPlayNext == true ? Self.upNextCountdown : nil
            )
        }

        let signature = "\(engine.status)|\(engine.rate)|\(Int(position / 15))"
        if signature != lastNowPlayingSignature {
            lastNowPlayingSignature = signature
            nowPlaying.update(
                title: controller.source?.title ?? request.title,
                subtitle: controller.source?.subtitle,
                duration: engine.duration,
                position: position,
                rate: controller.isPlaying ? engine.rate : 0
            )
        }
    }

    private func restartReporting(at position: TimeInterval) {
        guard let client, let item, let stream else { return }
        let reporter = PlaybackReporter(
            client: client,
            state: PlaybackReportState(
                itemID: item.id,
                mediaSourceID: stream.mediaSource.id,
                playSessionID: stream.playSessionID,
                position: position,
                isPaused: false,
                playMethod: stream.reportPlayMethod,
                audioStreamIndex: selectedAudioIndex,
                subtitleStreamIndex: selectedSubtitleIndex
            ),
            isTranscoding: stream.method == .transcode
        )
        reporter.start()
        self.reporter = reporter
    }

    private func shouldPresentUpNext(position: TimeInterval, duration: TimeInterval, ended: Bool) -> Bool {
        if ended { return true }
        if controller.activeOutro != nil { return true }
        let hasOutro = controller.segments.contains { $0.kind == .outro }
        return !hasOutro && duration > 0 && duration - position <= Self.upNextFallbackLead
    }
}
