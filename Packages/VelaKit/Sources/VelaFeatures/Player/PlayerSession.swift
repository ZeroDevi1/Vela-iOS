import CoreGraphics
import Foundation
import Observation
import VelaCore
import VelaData
import VelaNetwork
import VelaPlayer
#if os(iOS)
import AVKit
import UIKit
#endif

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
        var label: TrackLabel
        /// 图形字幕只能由服务器烧录，选择后会触发转码。
        var requiresBurnIn: Bool

        var title: String { label.title }
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
    private(set) var previousEpisode: MediaItem?
    /// 当前季的全部单集（剧集面板）；非剧集为空。
    private(set) var seasonEpisodes: [MediaItem] = []
    /// 「添加本地字幕」载入的文件名；选择服务器字幕、关闭字幕或换集 / 换内核重新起播时清除。
    private(set) var localSubtitleName: String?
    /// 最近一次截图，界面据此弹出分享提示；关闭提示时置 nil。
    var screenshot: CGImage?

    /// 本次会话中已写入服务器标签的排布及其条目；用于写入后隐藏「保存」入口。
    private var savedVRLayout: (itemID: String, layout: VRLayout)?

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
    /// 多段文件的全部段 id（按顺序）；在段之间切换时保留，换到其他条目时清空。
    private(set) var partIDs: [String] = []
    /// `partIDs` 对应的条目（分段面板用），顺序与 `partIDs` 相同；尚未取到或有段取不到时为空。
    private(set) var parts: [MediaItem] = []
    /// `partIDs` 第一段要播放的版本（见 `PlaybackRequest.Options.partsSourceID`）；与 `partIDs` 同时保留 / 清空。
    @ObservationIgnored private var partsSourceID: String?
    /// 上次发给 Trakt 的暂停状态；nil 表示本条目尚未 scrobble start。
    @ObservationIgnored private var traktPaused: Bool?
    /// 用户手动切换内核（失败后「用 KSPlayer 重试」或「更多 → 切换内核」）时强制使用的内核；nil 表示按设置自动选择。
    @ObservationIgnored private var engineOverride: PlaybackEngineMode?
    /// 自动模式下系统内核失败、已自动改用 KSPlayer 的条目：该条目之后（含重试）按 KSPlayer 起播，其它条目仍按设置先用系统内核。
    @ObservationIgnored private var ksPlayerFallbackItemID: String?
    /// 睡眠定时的到期时刻；到期暂停播放并清除。nil 表示未开启。与 Android 版一致，切集后继续计时。
    private(set) var sleepDeadline: Date?
    /// 睡眠定时预设（分钟），与 Android 版相同。
    static let sleepTimerPresets = [15, 30, 45, 60, 90]
    /// 「服务器转码为 4K」：本机解码器打不开超高分辨率片源时，让服务器缩小到该宽度重新编码；只对当前条目生效。
    @ObservationIgnored private var maxVideoWidthOverride: (itemID: String, width: Int)?
    /// 「串流画质」选择的码率上限（bit/s）；nil 为原画（不限制）。对本次播放的后续剧集也生效。
    private(set) var maxBitrateOverride: Int?
    /// 拖动预览独立转码会话的 PlaySessionId；切换条目或关闭时需要通知服务器结束转码。
    @ObservationIgnored private var previewPlaySessionID: String?
    /// 预加载的下一集码流（「预加载下一集」）；切到该集时直接使用，未使用则在关闭时结束其转码会话。
    @ObservationIgnored private var preloaded: (itemID: String, stream: ResolvedStream)?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// 下一集已预加载完成，界面在「下一集」按钮旁显示闪电标记。
    private(set) var isNextPreloaded = false
    /// 「即将跳过片头」提示中的片段与计划跳过的时刻。
    @ObservationIgnored private var pendingSkip: (segment: PlaybackSegment, at: Date)?
    /// 等画面尺寸确定后再应用的屏幕方向（「跟随视频」）。
    @ObservationIgnored private var pendingOrientation: PlayerOrientation?
    /// 因切到后台而暂停（回到前台时可自动继续）。
    @ObservationIgnored private var pausedForBackground = false
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []

    /// 本次起播已自动重试过一次（转码流偶发失败时）；开始正常播放后复位。
    @ObservationIgnored private var autoRetriedFailure = false
    /// 片段数据缺失时，离结尾多少秒提示下一集。
    private static let upNextFallbackLead: TimeInterval = 30
    /// 下一集自动播放倒计时（秒）。
    private static let upNextCountdown = 10

    init(request: PlaybackRequest) {
        self.request = request
    }

    // MARK: - 生命周期

    /// 是否已开始过准备；从画中画恢复时播放页复用会话，不能重新起播。
    @ObservationIgnored private var didPrepare = false

    /// 播放页出现时调用：只在首次准备，恢复呈现时跳过。
    func prepareIfNeeded(app: AppModel) async {
        guard !didPrepare else { return }
        await prepare(app: app)
    }

    func prepare(app: AppModel) async {
        didPrepare = true
        self.app = app
        let preferences = app.playerPreferences
        controller.preferences = preferences
        controller.onPlayNext = { [weak self] in self?.playNextEpisode() }
        controller.onPlayPrevious = { [weak self] in self?.playPreviousEpisode() }
        #if os(iOS)
        OrientationController.landscapeSide = preferences.landscapeSide
        observeLifecycle()
        #endif
        phase = .preparing
        do {
            switch request.target {
            case .url(let url):
                // 设置为 KSPlayer 时外部地址与离线文件都用它；
                // 否则离线文件中系统框架打不开的容器（MKV 等）交给 KSPlayer。
                var mode = preferences.engineMode
                #if DEBUG
                // 仅 Debug：`VELA_DEBUG_ENGINE=<auto|system|ksplayer>` 指定外部地址使用的内核（内核对比测试）。
                if let forced = ProcessInfo.processInfo.environment["VELA_DEBUG_ENGINE"].flatMap(PlaybackEngineMode.init(rawValue:)) {
                    mode = forced
                }
                #endif
                let preferred = PlaybackEngineChoice.requestedEngine(mode: mode, serverDownscaled: false)
                if preferred.directPlaysOriginal {
                    useEngine(preferred)
                } else if url.isFileURL, !OfflinePlayback.prefersSystemEngine(for: url) {
                    useEngine(.ksPlayer)
                }
                // 离线 / 外部地址没有服务器元数据，只按路径（文件名）识别 VR 排布。
                let vrLayout = VRLayoutParser.parse(mediaSourcePath: url.path)
                controller.load(PlaybackSource(url: url, title: request.title, vrLayout: vrLayout))
                // 外部地址不涉及服务器转码会话，预览可以直接用同一地址。
                controller.scrubPreview.configure(url.pathExtension.lowercased() == "m3u8" ? .stream(url) : .file(url),
                                                  allowsSweep: previewAllowsSweep(url))
                #if DEBUG
                scheduleDebugEngineSwitches()
                #endif
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
            scheduleOrientation(preferences.orientationOnEnter)
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
        preloadTask?.cancel()
        discardPreloaded()
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
        reporter?.stop(position: controller.engine.currentTime)
        traktStop()
        stopPreviewEncoding()
        nowPlaying.deactivate()
        controller.shutdown()
    }

    // MARK: - 起播

    /// - Parameter options: 只对用户从详情页发起的第一集生效；自动连播的下一集使用默认选择。
    /// - Parameter startTime: 指定起播位置（失败重试时沿用当前位置）；nil 按续播规则计算。
    private func start(item: MediaItem, options: PlaybackRequest.Options = .init(), startTime explicitStart: TimeInterval? = nil) async throws {
        guard let app, let server, let client else { return }
        self.item = item
        localSubtitleName = nil
        nextEpisode = nil
        previousEpisode = nil
        if item.seasonID == nil || !seasonEpisodes.contains(where: { $0.seasonID == item.seasonID }) {
            seasonEpisodes = []
        }
        autoSkipped = []
        endedReported = false
        app.refreshCapabilities()

        let startTime = explicitStart ?? options.startPosition ?? (options.startFromBeginning ? 0 : resumePosition(for: item))
        if let given = options.partIDs, given.contains(item.id) { partsSourceID = options.partsSourceID }
        // 从其它段回到第一段时沿用详情页选中的版本，否则会按「视频首选版本」换到平面版等其它版本。
        let mediaSourceID = options.mediaSourceID ?? (partIDs.first == item.id ? partsSourceID : nil)
        isNextPreloaded = false
        // 内核（与 Android 版一致）：设置为 KSPlayer 或手动切换时按 KSPlayer 能力请求，服务器直接给原文件；
        // 「服务器转码为 4K」需要服务器缩放后的码流，始终交给系统内核。
        let mode = engineOverride ?? (ksPlayerFallbackItemID == item.id ? .ksPlayer : app.playerPreferences.engineMode)
        let downscaled = maxVideoWidthOverride?.itemID == item.id
        var requested = PlaybackEngineChoice.requestedEngine(mode: mode, serverDownscaled: downscaled)
        var profile: DeviceProfile.Kind { requested.directPlaysOriginal ? .ksPlayer : .avFoundation }
        func resolve(_ profile: DeviceProfile.Kind) async throws -> ResolvedStream {
            try await app.playbackResolver.resolve(
                item: item, server: server, client: client,
                capabilities: capabilities(for: item),
                mediaSourceID: mediaSourceID,
                versionPreference: app.libraryPreferences.preferredVersion,
                startTime: startTime,
                audioStreamIndex: options.audioStreamIndex,
                profile: profile
            )
        }
        var stream: ResolvedStream
        // 预加载过的下一集：服务器已开始准备，直接使用（仅系统内核、默认选项、从续播点起播时）。
        if let preloaded, preloaded.itemID == item.id, options == .init(), explicitStart == nil, profile == .avFoundation {
            stream = preloaded.stream
            self.preloaded = nil
        } else {
            discardPreloaded()
            stream = try await resolve(profile)
        }
        configureTracks(for: stream)
        var initialSubtitle = initialSubtitleChoice(for: stream, preferredSubtitle: options.subtitleStreamIndex)
        let limitation = ksPlayerLimitation(for: stream, audioStreamIndex: options.audioStreamIndex)
        // 自动模式：要显示 MKV 等系统打不开的容器里的内嵌文本字幕时改用 KSPlayer 直放，由播放器从视频流读取字幕
        // （Android 用 MPV 也是如此）。否则服务器要读完整个文件才能提取字幕，文件在网盘上时实测超过 2 分钟。
        // 片源有系统内核更擅长的特性（全景声、未直通的杜比视界、原盘）时不切换。
        if let subtitle = initialSubtitle, PlaybackEngineChoice.switchesToKSPlayerForSubtitle(
            mode: mode, requested: requested, serverDownscaled: downscaled,
            subtitleNeedsPlayer: needsPlayerSideSubtitle(subtitle, in: stream), limitation: limitation
        ) {
            Log.player.info("内嵌字幕 #\(subtitle) 需要播放器读取，改用 KSPlayer 直放")
            requested = .ksPlayer
            stream = try await resolve(.ksPlayer)
            configureTracks(for: stream)
            initialSubtitle = initialSubtitleChoice(for: stream, preferredSubtitle: options.subtitleStreamIndex ?? subtitle)
        }
        // 服务器即使按直放能力也要求转码（编码不支持等）时，HLS 交给能效更高的系统内核。
        let engine = PlaybackEngineChoice.playbackEngine(requested: requested, isDirectPlay: stream.method == .directPlay)
        useEngine(engine)
        if let limitation {
            Log.player.info("片源限制：\(String(describing: limitation), privacy: .public) 请求 \(String(describing: requested), privacy: .public) 实际 \(String(describing: engine), privacy: .public)")
            // 用户要求 KSPlayer（设置或手动切换）时说明差异；原盘即使要求 KSPlayer 也由系统内核播放。
            if requested == .ksPlayer, engine == .ksPlayer || limitation == .discImage {
                controller.showMessage(limitation.message, symbol: "info.circle", duration: .seconds(6))
            }
        }
        apply(stream: stream, item: item, startTime: startTime, resetMetadata: true)
        configurePreview(for: stream, item: item)
        if let initialSubtitle {
            selectSubtitle(initialSubtitle, remember: false)
        } else {
            selectedSubtitleIndex = nil
        }
        if options.audioStreamIndex == nil { applyPreferredAudio(for: item, stream: stream) }
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
                      let self, self.item?.id == item.id else { return }
                // 上一集 / 下一集按全剧顺序，可跨季；剧集面板只列当前季。
                self.previousEpisode = index > 0 ? episodes[index - 1] : nil
                self.nextEpisode = episodes.indices.contains(index + 1) ? episodes[index + 1] : nil
                self.seasonEpisodes = episodes.filter { $0.seasonID == item.seasonID }
            }
        } else {
            linkParts(for: item, client: client, given: options.partIDs)
        }
    }

    /// 多段文件：确定各段顺序并预取上一段 / 下一段，复用「上一集 / 下一集」的播放与自动连播。
    private func linkParts(for item: MediaItem, client: MediaServerClient, given: [String]?) {
        if let given, given.contains(item.id) {
            partIDs = given
        } else if !partIDs.contains(item.id) {
            partIDs = []
            partsSourceID = nil
        }
        if parts.map(\.id) != partIDs { parts = [] }
        Task { [weak self] in
            guard let self else { return }
            if self.partIDs.isEmpty, (item.partCount ?? 0) > 1,
               let additional = try? await client.additionalParts(itemID: item.id) {
                self.partIDs = [item.id] + additional.map(\.id)
                self.parts = [item] + additional
            }
            guard let index = self.partIDs.firstIndex(of: item.id), self.item?.id == item.id else { return }
            let ids = self.partIDs
            // 详情页只传来各段 id：逐段取条目（段数很少），在段之间切换时沿用已取到的。
            var loaded = Dictionary(self.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if loaded.isEmpty {
                loaded = await withTaskGroup(of: MediaItem?.self) { group in
                    for id in ids {
                        group.addTask { id == item.id ? item : try? await client.item(id: id) }
                    }
                    var result: [String: MediaItem] = [:]
                    for await part in group {
                        if let part { result[part.id] = part }
                    }
                    return result
                }
            }
            guard self.item?.id == item.id, self.partIDs == ids else { return }
            // 有段取不到时不显示分段面板（列表不完整），相邻段仍按取到的结果提供。
            if loaded.count == ids.count { self.parts = ids.compactMap { loaded[$0] } }
            self.previousEpisode = index > 0 ? loaded[ids[index - 1]] : nil
            self.nextEpisode = ids.indices.contains(index + 1) ? loaded[ids[index + 1]] : nil
        }
    }
    /// 横屏控制层左上角的剧集 / 电影 Logo；没有 Logo 图时为 nil。
    var logoURL: URL? {
        guard let item, let client else { return nil }
        return client.logoURL(for: item, maxWidth: 480)
    }

    /// 标题旁的动态范围标记；SDR 或未知时为 nil。
    var dynamicRangeLabel: String? {
        guard let video = stream?.mediaSource.videoStream else { return nil }
        return Self.dynamicRangeLabel(for: video)
    }

    /// 依次使用 Jellyfin 的 `VideoRangeType`、Emby 的 `ExtendedVideoType`，最后按传递函数推断
    /// （与 Android 版按解码色彩信息判断的结果一致：PQ 为 HDR10，HLG 为 HLG）。
    static func dynamicRangeLabel(for video: MediaStreamInfo) -> String? {
        if let range = video.videoRangeType {
            if range.hasPrefix("DOVI") { return "Dolby Vision" }
            switch range {
            case "HDR10Plus": return "HDR10+"
            case "HDR10": return "HDR10"
            case "HLG": return "HLG"
            case "SDR": return nil
            default: break
            }
        }
        switch video.extendedVideoType?.lowercased() {
        case "dolbyvision": return "Dolby Vision"
        case "hdr10plus": return "HDR10+"
        case "hdr10": return "HDR10"
        case "hyperloggamma": return "HLG"
        default: break
        }
        switch video.colorTransfer?.lowercased() {
        case "smpte2084": return "HDR10"
        case "arib-std-b67": return "HLG"
        default: break
        }
        return video.videoRange?.uppercased() == "HDR" ? "HDR" : nil
    }

    /// 当前是多段文件中的第几段（从 1 开始）与总段数；非多段为 nil。
    var partPosition: (index: Int, count: Int)? {
        guard partIDs.count > 1, let item, let index = partIDs.firstIndex(of: item.id) else { return nil }
        return (index + 1, partIDs.count)
    }

    /// 已看完（≥ 95%）的条目从头播放，其余从上次位置继续；关闭「从上次进度播放」时总是从头。
    private func resumePosition(for item: MediaItem) -> TimeInterval {
        guard app?.playerPreferences.resumePlayback != false else { return 0 }
        guard let ticks = item.playbackPositionTicks, ticks > 0 else { return 0 }
        if let fraction = item.playedFraction, fraction >= 0.95 { return 0 }
        return Ticks.seconds(ticks)
    }

    private func apply(stream: ResolvedStream, item: MediaItem, startTime: TimeInterval, resetMetadata: Bool) {
        self.stream = stream
        (controller.engine as? any MultichannelSpatializationConfigurable)?.allowsMultichannelSpatialization = app?.playerPreferences.nativeAudio ?? true
        Log.player.info("播放方式：\(stream.method.rawValue, privacy: .public) \(Self.redacted(stream.url), privacy: .public)")
        let video = stream.mediaSource.videoStream
        Log.player.info("视频流：\(video?.codec ?? "-", privacy: .public) tag=\(video?.codecTag ?? "-", privacy: .public) range=\(video?.videoRangeType ?? "-", privacy: .public) depth=\(video?.bitDepth ?? 0) container=\(stream.mediaSource.container ?? "-", privacy: .public)")
        let vrLayout = Self.vrLayout(stream: stream, item: item)
        #if os(macOS)
        // 系统画中画只显示码流自带的字幕轨：转封装 HLS 带上服务器的字幕组（平时不选中，字幕仍由应用绘制）。
        let url = controller.engine.kind == .avFoundation ? stream.urlWithSubtitlesInManifest : stream.url
        controller.manifestSubtitle = { [weak self] in
            guard let self, self.localSubtitleName == nil, let stream = self.stream, let index = self.selectedSubtitleIndex,
                  let ordinal = stream.manifestSubtitleOrdinal(streamIndex: index) else { return nil }
            let name = stream.mediaSource.subtitleStreams.first { $0.index == index }?.displayTitle
            return (ordinal, name)
        }
        #else
        let url = stream.url
        #endif
        controller.load(
            PlaybackSource(
                url: url,
                title: item.seriesName ?? item.name,
                subtitle: item.episodeLabel.map { "\($0) · \(item.name)" },
                startTime: startTime,
                vrLayout: vrLayout,
                forwardBufferDuration: app?.playerPreferences.forwardBufferDuration(
                    bitrate: stream.mediaSource.bitrate, isMetered: app?.network.isMetered ?? true
                ) ?? 0
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

    /// 音轨 / 字幕选项与当前音轨。
    private func configureTracks(for stream: ResolvedStream) {
        let source = stream.mediaSource
        audioOptions = source.audioStreams.map {
            TrackOption(index: $0.index, label: Self.label(for: $0), requiresBurnIn: false)
        }
        subtitleOptions = source.subtitleStreams.map {
            // 文本字幕由客户端渲染（WebVTT 或随 HLS 下发）；图形字幕只能由服务器烧录。
            TrackOption(index: $0.index, label: Self.label(for: $0), requiresBurnIn: !$0.isTextSubtitle)
        }
        selectedAudioIndex = stream.audioStreamIndex ?? source.defaultAudioStreamIndex ?? audioOptions.first?.index
    }

    /// 起播时开启哪条字幕；nil 为关闭。须在 `configureTracks` 之后调用。
    /// - Parameter preferredSubtitle: 详情页选择的字幕；-1 关闭，nil 按规则选择。
    private func initialSubtitleChoice(for stream: ResolvedStream, preferredSubtitle: Int?) -> Int? {
        // 用户显式选择：图形字幕也照办（会触发烧录转码）。
        if let preferredSubtitle { return preferredSubtitle >= 0 ? preferredSubtitle : nil }
        // 优先级：本作品记住的字幕语言 > 首选字幕语言 > 服务器按用户语言偏好给出的默认。
        // 图形字幕不自动开启，避免一起播就触发转码。
        let source = stream.mediaSource
        let preferences = app?.playerPreferences
        let textual = source.subtitleStreams.filter { stream in
            subtitleOptions.first { $0.index == stream.index }?.requiresBurnIn == false
        }
        if preferences?.rememberSubtitle == true, let item, let remembered = TrackMemory.subtitleLanguage(for: item) {
            if remembered == TrackMemory.subtitleOff { return nil }
            if let match = TrackMemory.match(remembered, in: textual) { return match.index }
        }
        if let match = TrackMemory.match(preferences?.preferredSubtitleLanguage, in: textual) { return match.index }
        if let index = source.defaultSubtitleStreamIndex, index >= 0,
           let option = subtitleOptions.first(where: { $0.index == index }), !option.requiresBurnIn {
            return index
        }
        return nil
    }

    /// 起播后按「记住所选音轨」与「音频首选语言」切换音轨（与服务器默认相同时不做任何事）。
    private func applyPreferredAudio(for item: MediaItem, stream: ResolvedStream) {
        guard let preferences = app?.playerPreferences else { return }
        let streams = stream.mediaSource.audioStreams
        let remembered = preferences.rememberAudioTrack ? TrackMemory.audioLanguage(for: item) : nil
        guard let match = TrackMemory.match(remembered, in: streams) ?? TrackMemory.match(preferences.preferredAudioLanguage, in: streams),
              match.index != selectedAudioIndex else { return }
        selectAudio(match.index, remember: false)
    }

    private static func label(for stream: MediaStreamInfo) -> TrackLabel {
        stream.trackLabel ?? TrackLabel(title: "轨道 \(stream.index)", details: [], flags: [])
    }

    /// 音轨面板的「静音」：只关闭输出，保留当前音轨。
    func muteAudio() {
        controller.engine.setMuted(true)
    }

    /// 选择任一音轨（包括当前音轨）都会取消静音。
    /// - Parameter remember: 用户手动选择时为 true，按设置记住该作品的音轨语言。
    func selectAudio(_ index: Int, remember: Bool = true) {
        controller.engine.setMuted(false)
        if remember, app?.playerPreferences.rememberAudioTrack == true, let item,
           let language = stream?.mediaSource.audioStreams.first(where: { $0.index == index })?.language {
            TrackMemory.rememberAudio(language, for: item)
        }
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
    /// - Parameter remember: 用户手动选择时为 true，按设置记住该作品的字幕语言（含「关闭」）。
    func selectSubtitle(_ index: Int?, remember: Bool = true) {
        guard let stream, let client, let item else { return }
        if remember, app?.playerPreferences.rememberSubtitle == true {
            let language = index.flatMap { i in stream.mediaSource.subtitleStreams.first { $0.index == i }?.language }
            TrackMemory.rememberSubtitle(index == nil ? TrackMemory.subtitleOff : language, for: item)
        }
        trackError = nil
        subtitleTask?.cancel()
        selectedSubtitleIndex = index
        localSubtitleName = nil

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
        let embeddedEngine = controller.engine as? any EmbeddedSubtitleProviding
        guard let index else {
            controller.subtitleTrack = nil
            embeddedEngine?.selectEmbeddedSubtitle(ordinal: nil)
            reporter?.flush(position: controller.engine.currentTime, audioStreamIndex: selectedAudioIndex, subtitleStreamIndex: nil)
            return
        }
        // 系统内核在转封装播放 MKV 等容器时选了内嵌文本字幕：除非设置为只用系统内核，否则换到 KSPlayer 直放读取字幕。
        if controller.engine.kind == .avFoundation, (engineOverride ?? app?.playerPreferences.engineMode) != .system,
           maxVideoWidthOverride?.itemID != item.id, needsPlayerSideSubtitle(index, in: stream),
           ksPlayerLimitation(for: stream, audioStreamIndex: selectedAudioIndex)?.prefersSystem != true {
            controller.showMessage("切换到 KSPlayer，直接读取内嵌字幕", symbol: "captions.bubble", duration: .seconds(3))
            restart(with: .ksPlayer, subtitle: index)
            return
        }
        // KSPlayer 直放原文件：内嵌文本字幕由播放器从视频流读取（与 Android / SenPlayer 相同），不请求服务器提取。
        let embedded = stream.mediaSource.subtitleStreams.filter { $0.isExternal != true }
        if let embeddedEngine, let ordinal = embedded.firstIndex(where: { $0.index == index }), embedded[ordinal].isTextSubtitle {
            controller.subtitleTrack = nil
            embeddedEngine.selectEmbeddedSubtitle(ordinal: ordinal)
            reporter?.flush(position: controller.engine.currentTime, audioStreamIndex: selectedAudioIndex, subtitleStreamIndex: index)
            preloadFullSubtitle(index: index, stream: stream, item: item, client: client, replacing: embeddedEngine)
            return
        }
        embeddedEngine?.selectEmbeddedSubtitle(ordinal: nil)
        let mediaSourceID = stream.mediaSource.id
        subtitleTask = Task {
            // 内嵌字幕由服务器从整个视频文件中提取，可能要等较久：超过 3 秒给出提示，避免以为字幕坏了。
            let isEmbedded = stream.mediaSource.subtitleStreams.first { $0.index == index }?.isExternal != true
            let hint = Task { [weak self] in
                try await Task.sleep(for: .seconds(3))
                self?.controller.showMessage("正在等待服务器提取字幕…", symbol: "captions.bubble", duration: .seconds(4))
                // 内嵌字幕要服务器读完整个文件（网盘上的大文件可能要数分钟）；KSPlayer 直接从视频流读取，无需等待。
                guard isEmbedded, self?.canSwitchEngine == true else { return }
                try await Task.sleep(for: .seconds(7))
                self?.controller.showMessage("服务器提取内嵌字幕较慢，可在「更多 → 使用 KSPlayer 内核」直接读取字幕", symbol: "captions.bubble", duration: .seconds(6))
            }
            defer { hint.cancel() }
            let started = Date.now
            let codec = stream.mediaSource.subtitleStreams.first { $0.index == index }?.codec
            do {
                let vtt = try await client.subtitleText(itemID: item.id, mediaSourceID: mediaSourceID, streamIndex: index, codec: codec)
                Log.player.info("字幕 #\(index)（\(codec ?? "-", privacy: .public)）下载耗时 \(String(format: "%.1f", Date.now.timeIntervalSince(started)), privacy: .public)s")
                guard !Task.isCancelled, selectedSubtitleIndex == index else { return }
                let cues = WebVTTParser.parse(vtt)
                // 诊断：条数与首条时间可判断「解析不出」（0 条）或「时间轴偏移」（首条时间异常）。
                Log.player.info("字幕 #\(index)：\(vtt.utf8.count) 字节，\(cues.count) 条，首条 \(cues.first.map { String(format: "%.2f", $0.start) } ?? "-", privacy: .public)s")
                if cues.isEmpty {
                    trackError = "字幕为空或格式无法识别"
                    selectedSubtitleIndex = nil
                    return
                }
                var track = SubtitleTrack(cues: cues)
                track.delay = controller.subtitleTrack?.delay ?? 0
                controller.subtitleTrack = track
                reporter?.flush(position: controller.engine.currentTime, audioStreamIndex: selectedAudioIndex, subtitleStreamIndex: index)
            } catch {
                guard !Task.isCancelled else { return }
                Log.player.error("字幕 #\(index) 加载失败：\(error.localizedDescription, privacy: .public)")
                trackError = "字幕加载失败：\(error.localizedDescription)"
                selectedSubtitleIndex = nil
            }
        }
    }

    /// 后台向服务器取完整字幕，取到后替换 KSPlayer 边播边解码的内嵌字幕。
    ///
    /// KSPlayer 只能解码拖动点之后的字幕包：拖到一句字幕的中间（如 10–20 秒的字幕拖到 15 秒）要等下一句才有字幕。
    /// 完整字幕按时间查询，任意位置都能立即显示当前这句（与 Android mpv 的字幕预读效果一致）。
    /// 服务器首次提取内嵌字幕要读完整个文件（网盘上较慢），之后有缓存；期间仍由 KSPlayer 显示，失败时保持现状。
    private func preloadFullSubtitle(index: Int, stream: ResolvedStream, item: MediaItem, client: MediaServerClient, replacing embeddedEngine: any EmbeddedSubtitleProviding) {
        let codec = stream.mediaSource.subtitleStreams.first { $0.index == index }?.codec
        let mediaSourceID = stream.mediaSource.id
        subtitleTask = Task {
            do {
                let vtt = try await client.subtitleText(itemID: item.id, mediaSourceID: mediaSourceID, streamIndex: index, codec: codec)
                let cues = WebVTTParser.parse(vtt)
                guard !Task.isCancelled, selectedSubtitleIndex == index, controller.engine === embeddedEngine, !cues.isEmpty else { return }
                var track = SubtitleTrack(cues: cues)
                track.delay = controller.subtitleTrack?.delay ?? 0
                controller.subtitleTrack = track
                embeddedEngine.selectEmbeddedSubtitle(ordinal: nil)
                Log.player.info("字幕 #\(index) 已换用服务器完整字幕（\(cues.count) 条）")
            } catch {
                guard !Task.isCancelled else { return }
                Log.player.info("字幕 #\(index) 完整字幕预取失败，继续使用 KSPlayer 内嵌字幕：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 在线字幕

    /// 在线搜索字幕（服务器的字幕插件完成搜索），并记入「字幕搜索记录」。
    func searchRemoteSubtitles(language: String) async throws -> [RemoteSubtitle] {
        guard let client, let item else { return [] }
        app?.playerPreferences.rememberSubtitleSearch(language: language)
        let results = try await client.searchRemoteSubtitles(itemID: item.id, mediaSourceID: stream?.mediaSource.id, language: language)
        // 哈希精确匹配的排前面，其余按下载量。
        return results.sorted { ($0.isHashMatch == true ? 1 : 0, $0.downloadCount ?? 0) > ($1.isHashMatch == true ? 1 : 0, $1.downloadCount ?? 0) }
    }

    /// 让服务器下载字幕，等它出现在媒体流列表后直接选中。
    ///
    /// 服务器下载后要刷新条目元数据才会列出新字幕：每 1.5 秒重新读取一次，最多等约 12 秒；
    /// 超时仍未出现时抛错，字幕已保存在服务器上，重新打开播放器即可看到。
    func downloadRemoteSubtitle(_ subtitle: RemoteSubtitle) async throws {
        guard let client, let item, let current = stream else { return }
        let known = Set(current.mediaSource.subtitleStreams.map(\.index))
        try await client.downloadRemoteSubtitle(itemID: item.id, subtitleID: subtitle.id)
        for _ in 0..<8 {
            try await Task.sleep(for: .seconds(1.5))
            let info = try await client.playbackInfo(
                itemID: item.id, mediaSourceID: current.mediaSource.id, capabilities: capabilities(for: item)
            )
            guard let source = info.mediaSources.first(where: { $0.id == current.mediaSource.id }),
                  let added = source.subtitleStreams.first(where: { !known.contains($0.index) }),
                  self.item?.id == item.id, var updated = stream else { continue }
            // 只更新字幕列表，不重新起播。
            updated.mediaSource = source
            stream = updated
            subtitleOptions = source.subtitleStreams.map {
                TrackOption(index: $0.index, label: Self.label(for: $0), requiresBurnIn: !$0.isTextSubtitle)
            }
            selectSubtitle(added.index)
            return
        }
        throw RemoteSubtitleError.notListedYet
    }

    enum RemoteSubtitleError: LocalizedError {
        case notListedYet
        var errorDescription: String? { "字幕已下载到服务器，但服务器尚未刷新完条目，请稍后重新打开播放器" }
    }

    // MARK: - 本地字幕

    /// 载入本机的 SRT / ASS / SSA / VTT 字幕文件（与 Android「添加本地字幕」相同），替换当前字幕，沿用当前延迟。
    /// 只在本次播放有效，不上传服务器。文件来自 `fileImporter`，需在安全作用域内读取。
    func loadLocalSubtitle(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let cues: [SubtitleCue]
        do {
            let data = try Data(contentsOf: url)
            guard let text = MediaServerClient.decodeSubtitleText(data) else {
                trackError = "无法识别字幕文件的编码"
                return
            }
            cues = SubtitleFileParser.parse(text, fileExtension: url.pathExtension)
        } catch {
            trackError = "无法读取字幕文件：\(error.localizedDescription)"
            return
        }
        guard !cues.isEmpty else {
            trackError = "字幕为空或格式无法识别"
            return
        }
        trackError = nil
        subtitleTask?.cancel()
        (controller.engine as? any EmbeddedSubtitleProviding)?.selectEmbeddedSubtitle(ordinal: nil)
        // 烧录字幕会叠在画面里，换回不烧录的码流。
        if let stream, stream.burnedSubtitleIndex != nil {
            Task { await reloadStream(audioStreamIndex: selectedAudioIndex, burnSubtitleIndex: nil) }
        }
        selectedSubtitleIndex = nil
        var track = SubtitleTrack(cues: cues)
        track.delay = controller.subtitleTrack?.delay ?? 0
        controller.subtitleTrack = track
        localSubtitleName = url.lastPathComponent
        controller.showMessage("已加载字幕：\(url.lastPathComponent)", symbol: "captions.bubble", duration: .seconds(3))
    }

    func adjustSubtitleDelay(by seconds: TimeInterval) {
        controller.subtitleTrack?.delay += seconds
    }

    /// 当前字幕延迟（秒）。
    var subtitleDelay: TimeInterval {
        controller.subtitleTrack?.delay ?? 0
    }

    /// 是否有字幕在显示（决定是否提供延迟调整）。
    var hasActiveSubtitle: Bool {
        controller.subtitleTrack != nil
    }

    /// 与 Android 版一致：路径、名称、标签、3D 格式与画面尺寸都参与识别。`extraTags` 用于预演写入标签后的识别结果。
    private static func vrLayout(stream: ResolvedStream, item: MediaItem, extraTags: [String] = []) -> VRLayout? {
        let video = stream.mediaSource.videoStream
        return VRLayoutParser.parse(
            mediaSourcePath: stream.mediaSource.path,
            itemPath: item.path,
            itemName: item.name,
            mediaSourceName: stream.mediaSource.name,
            tags: extraTags + item.tags,
            video3DFormat: item.video3DFormat,
            videoWidth: video?.width,
            videoHeight: video?.height
        )
    }

    /// 手动选择的排布能否写成服务器标签：仅服务器条目，且写入后自动识别确实会得到这一排布。
    /// 文件名已带投影标记（优先于标签）或画面尺寸与排布不符时，标签不起作用，不提供入口。
    var canSaveVRLayoutTag: Bool {
        guard client != nil, let item, let stream, let layout = controller.vrLayoutOverride,
              layout != controller.source?.vrLayout, savedVRLayout?.itemID != item.id || savedVRLayout?.layout != layout
        else { return false }
        return Self.vrLayout(stream: stream, item: item, extraTags: [layout.serverTag]) == layout
    }

    /// 把手动选择的排布写成条目标签，之后在任何设备上都能自动识别；同时去掉其它排布的标签。
    /// 需要管理员权限；失败时提示原因，不影响当前播放。
    func saveVRLayoutTag() {
        guard canSaveVRLayoutTag, let client, let item, let layout = controller.vrLayoutOverride else { return }
        let tag = layout.serverTag
        let others = VRLayoutParser.manualOptions.map(\.serverTag).filter { $0 != tag }
        Task { [weak self] in
            do {
                try await client.updateTags(itemID: item.id, adding: [tag], removing: others)
                self?.savedVRLayout = (item.id, layout)
                self?.controller.showMessage("已写入标签 \(tag)，下次播放自动识别", symbol: "tag", duration: .seconds(3))
            } catch APIError.http(status: 403, _) {
                self?.controller.showMessage("写入标签需要服务器管理员权限", symbol: "exclamationmark.triangle", duration: .seconds(3.5))
            } catch {
                self?.controller.showMessage("写入标签失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: .seconds(3.5))
            }
        }
    }

    /// 能否切换内核。服务器条目都可切换：按新内核的能力重新向服务器选流，服务器不能直放时仍回到系统内核；
    /// 离线文件 / 外部地址直接用新内核从当前位置重新打开同一地址（系统内核打不开的容器会显示播放出错）。
    var canSwitchEngine: Bool {
        if item != nil { return true }
        if case .url = request.target { return controller.source != nil }
        return false
    }

    /// 这条字幕是否必须由播放器自己从视频流读取：系统框架打不开的容器（MKV 等，服务器转封装播放）中的内嵌文本字幕。
    /// 这类字幕若交给服务器提取，需要读完整个视频文件。
    private func needsPlayerSideSubtitle(_ index: Int, in stream: ResolvedStream) -> Bool {
        guard let info = stream.mediaSource.subtitleStreams.first(where: { $0.index == index }) else { return false }
        return PlaybackEngineChoice.needsPlayerSideSubtitle(
            isTranscode: stream.method == .transcode,
            container: stream.mediaSource.container,
            isEmbeddedText: info.isExternal != true && info.isTextSubtitle
        )
    }

    /// KSPlayer 播放当前片源时不如系统内核之处（阶段 4c 规则见 `PlaybackEngineChoice.ksPlayerLimitation`）。
    /// - Parameter audioStreamIndex: 要播放的音轨；nil 为服务器默认音轨。
    private func ksPlayerLimitation(for stream: ResolvedStream, audioStreamIndex: Int?) -> KSPlayerLimitation? {
        let source = stream.mediaSource
        let audioIndex = audioStreamIndex ?? stream.audioStreamIndex ?? source.defaultAudioStreamIndex
        let audio = source.audioStreams.first { $0.index == audioIndex } ?? source.audioStreams.first
        let traits = PlaybackEngineChoice.SourceTraits(
            isDiscImage: source.isDiscImage,
            dolbyVisionProfile: source.videoStream?.dolbyVisionProfile,
            isAtmosEAC3: audio.map { $0.isDolbyAtmos && $0.codec?.lowercased() == "eac3" } ?? false
        )
        return PlaybackEngineChoice.ksPlayerLimitation(traits, passthrough: app?.playerPreferences.enableAtmos ?? true)
    }

    /// 原盘只能由服务器转封装后用系统内核播放，不能换到 KSPlayer。
    private func refusesKSPlayerForDisc() -> Bool {
        guard let stream, stream.mediaSource.isDiscImage else { return false }
        controller.showMessage(KSPlayerLimitation.discImage.message, symbol: "info.circle", duration: .seconds(4))
        return true
    }

    /// 换用另一个内核，从当前位置继续（与 Android 版「使用 ExoPlayer / MPV」对应）。
    func switchEngine(to kind: PlaybackEngineKind) {
        guard canSwitchEngine, kind != controller.engine.kind else { return }
        if kind == .ksPlayer, refusesKSPlayerForDisc() { return }
        let mode: PlaybackEngineMode = switch kind {
        case .avFoundation: .system
        case .ksPlayer: .ksPlayer
        }
        restart(with: mode)
    }

    /// 系统内核播放失败（或解不出画面）时改用 KSPlayer 从当前位置重试。
    func retryWithKSPlayer() {
        guard controller.engine.kind == .avFoundation, !refusesKSPlayerForDisc() else { return }
        restart(with: .ksPlayer)
    }

    /// 自动模式下系统内核报错或解不出画面时，改用 KSPlayer 从当前位置继续（规则见 `PlaybackEngineChoice.fallsBackToKSPlayer`）。
    /// 不满足条件时返回 false，由错误界面 / 无画面卡片让用户选择。
    private func fallBackToKSPlayerIfNeeded(after failure: PlaybackEngineChoice.SystemEngineFailure, detail: String) -> Bool {
        guard controller.engine.kind == .avFoundation, canSwitchEngine,
              PlaybackEngineChoice.fallsBackToKSPlayer(
                  after: failure,
                  mode: engineOverride ?? app?.playerPreferences.engineMode ?? .auto,
                  serverDownscaled: isServerDownscaled,
                  isDiscImage: stream?.mediaSource.isDiscImage ?? false,
                  alreadyFellBack: item != nil && ksPlayerFallbackItemID == item?.id
              ) else { return false }
        Log.player.error("系统内核失败，自动改用 KSPlayer：\(detail, privacy: .public)")
        controller.showMessage("系统内核无法播放，已自动改用 KSPlayer", symbol: "arrow.triangle.2.circlepath", duration: .seconds(3))
        if let item {
            ksPlayerFallbackItemID = item.id
            restart(with: nil)
        } else {
            // 离线文件 / 外部地址：改为固定使用 KSPlayer，模式不再是「自动」，不会重复回退。
            restart(with: .ksPlayer)
        }
        return true
    }

    /// 本机解码器打不开的超高分辨率片源（如 8192 宽的 8K VR）：让服务器缩小到 4K 重新编码，从当前位置重试。
    /// 只对当前条目生效；服务器需开启视频转码，且 8K 实时转码对服务器性能要求较高。
    func retryWithServerDownscale() {
        guard let item else { return }
        maxVideoWidthOverride = (item.id, Self.downscaleWidth)
        restart(with: .system)
    }

    /// 「服务器转码为 4K」的宽度上限。VR 片源多为 2:1，3840 宽即 3840×1920。
    static let downscaleWidth = 3840

    /// 当前是否为「服务器转码为 4K」的码流。
    var isServerDownscaled: Bool {
        guard let item, let override = maxVideoWidthOverride else { return false }
        return override.itemID == item.id
    }

    /// 发给服务器的能力声明：在设置之上叠加当前条目的分辨率上限。
    private func capabilities(for item: MediaItem) -> PlaybackCapabilities {
        var caps = app?.effectivePlaybackCapabilities ?? PlaybackCapabilityProbe.current()
        if let override = maxVideoWidthOverride, override.itemID == item.id { caps.maxVideoWidth = override.width }
        if let maxBitrateOverride { caps.maxStreamingBitrate = min(caps.maxStreamingBitrate, maxBitrateOverride) }
        return caps
    }

    // MARK: - 串流画质

    /// 「串流画质」选项（与 Android 版一致）。片源码率高于上限时由服务器转码，低于上限时仍直接播放。
    struct QualityOption: Identifiable, Hashable {
        var label: String
        /// bit/s；nil 为原画。
        var bitrate: Int?
        var id: String { label }
    }

    static let qualityOptions: [QualityOption] = [QualityOption(label: "原画", bitrate: nil)]
        + [200, 160, 140, 120, 100, 80, 60].map { QualityOption(label: "4K（\($0) Mbps）", bitrate: $0 * 1_000_000) }
        + [40, 20, 15, 10, 8].map { QualityOption(label: "1080P（\($0) Mbps）", bitrate: $0 * 1_000_000) }
        + [4, 3, 2].map { QualityOption(label: "720P（\($0) Mbps）", bitrate: $0 * 1_000_000) }
        + [QualityOption(label: "480P（1.5 Mbps）", bitrate: 1_500_000)]

    /// 切换码率上限，从当前位置重新向服务器请求码流（保留版本、音轨与字幕）。
    func setMaxBitrate(_ bitrate: Int?) {
        guard bitrate != maxBitrateOverride else { return }
        maxBitrateOverride = bitrate
        restart(with: engineOverride ?? app?.playerPreferences.engineMode ?? .auto)
    }

    /// 换内核从当前位置重新起播，保留当前版本、音轨与字幕选择。
    /// - Parameter mode: 强制使用的内核；nil 不改 `engineOverride`，仍按设置与自动回退选择（只用于服务器条目）。
    private func restart(with mode: PlaybackEngineMode?, subtitle: Int?? = nil) {
        let position = controller.engine.currentTime
        guard let item else {
            if let mode { restartURL(with: mode, at: position) }
            return
        }
        if let mode { engineOverride = mode }
        reporter?.stop(position: position)
        reporter = nil
        let keptSubtitle = subtitle ?? selectedSubtitleIndex
        let options = PlaybackRequest.Options(
            mediaSourceID: stream?.mediaSource.id,
            audioStreamIndex: selectedAudioIndex,
            subtitleStreamIndex: keptSubtitle ?? -1
        )
        Task {
            phase = .preparing
            do {
                try await start(item: item, options: options, startTime: position)
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    #if DEBUG
    /// 仅 Debug：`VELA_DEBUG_SWITCH_ENGINES=system,ksplayer,…` 起播后每 8 秒依次切换到列出的内核，
    /// 用于在模拟器上复现切换内核的问题（模拟器点击注入有数秒延迟，难以手动卡准时机）。
    private func scheduleDebugEngineSwitches() {
        // `VELA_DEBUG_AUTO_PIP=<秒>`：起播后到点自动进入画中画（核对 macOS 小窗画面与窗口去留）。
        if let delay = ProcessInfo.processInfo.environment["VELA_DEBUG_AUTO_PIP"].flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.controller.requestPictureInPictureToggle()
            }
        }
        // `VELA_DEBUG_SUBTITLE=<字幕地址>`：起播后加载外挂字幕（画中画叠字幕排查用）。
        if let subtitle = ProcessInfo.processInfo.environment["VELA_DEBUG_SUBTITLE"].flatMap(URL.init(string:)) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.loadLocalSubtitle(from: subtitle)
            }
        }
        if let script = ProcessInfo.processInfo.environment["VELA_DEBUG_SCRIPT"] {
            runDebugScript(script)
        }
        guard let list = ProcessInfo.processInfo.environment["VELA_DEBUG_SWITCH_ENGINES"] else { return }
        let modes = list.split(separator: ",").compactMap { PlaybackEngineMode(rawValue: String($0)) }
        Task { [weak self] in
            for mode in modes {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !self.closed else { return }
                Log.player.info("Debug 切换内核 → \(mode.rawValue, privacy: .public)，切换前 \(self.controller.engine.kind.title, privacy: .public) 位于 \(String(format: "%.1f", self.controller.engine.currentTime), privacy: .public)s")
                self.restart(with: mode)
            }
        }
    }

    /// 仅 Debug：`VELA_DEBUG_SCRIPT="5:seek=30,10:rate=2,15:pause,18:play,20:mute,22:unmute,24:audio=1"`，
    /// 起播后按秒数依次操作内核，每步操作前后与 2 秒后各记一行状态（时间、状态、倍速），
    /// 用于在 Mac 上不经界面验证内核的跳转、倍速、暂停、静音、切换音轨（日志分类 player，前缀「Debug 脚本」）。
    private func runDebugScript(_ script: String) {
        let steps = script.split(separator: ",").compactMap { step -> (at: Double, action: Substring)? in
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]) else { return nil }
            return (at, parts[1])
        }
        Task { [weak self] in
            var elapsed = 0.0
            for step in steps.sorted(by: { $0.at < $1.at }) {
                try? await Task.sleep(for: .seconds(step.at - elapsed))
                elapsed = step.at
                guard let self, !self.closed else { return }
                let engine = self.controller.engine
                self.logDebugState("前 \(step.action)")
                let argument = step.action.split(separator: "=").last.map(String.init) ?? ""
                switch step.action.split(separator: "=").first {
                case "seek": await engine.seek(to: Double(argument) ?? 0)
                case "rate": engine.setRate(Float(argument) ?? 1)
                case "pause": engine.pause()
                case "play": engine.play()
                case "mute": engine.setMuted(true)
                case "unmute": engine.setMuted(false)
                case "audio": _ = await engine.selectAudioTrack(ordinal: Int(argument) ?? 0)
                default: Log.player.error("Debug 脚本：未知操作 \(step.action, privacy: .public)")
                }
                self.logDebugState("后 \(step.action)")
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.logDebugState("2 秒后 \(step.action)")
                }
            }
        }
    }

    private func logDebugState(_ label: String) {
        let engine = controller.engine
        Log.player.info("Debug 脚本 \(label, privacy: .public)：time=\(String(format: "%.2f", engine.preciseCurrentTime), privacy: .public) status=\(String(describing: engine.status), privacy: .public) rate=\(engine.rate)")
    }
    #endif

    /// 离线文件 / 外部地址换内核：没有服务器选流，直接用新内核从当前位置打开同一地址。
    private func restartURL(with mode: PlaybackEngineMode, at position: TimeInterval) {
        guard var source = controller.source else { return }
        engineOverride = mode
        useEngine(PlaybackEngineChoice.requestedEngine(mode: mode, serverDownscaled: false))
        source.startTime = position
        Log.player.info("切换内核：\(self.controller.engine.kind.title, privacy: .public) 从 \(String(format: "%.1f", position), privacy: .public)s 起播")
        controller.load(source, resetMetadata: false)
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
                capabilities: capabilities(for: item),
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
        playEpisode(next)
    }

    func playPreviousEpisode() {
        guard let previous = previousEpisode else { return }
        playEpisode(previous)
    }

    /// 在当前会话内切换到同剧的另一集（下一集、上一集或剧集面板中选择）。
    func playEpisode(_ episode: MediaItem) {
        guard episode.id != item?.id else { return }
        traktStop()
        reporter?.stop(position: controller.engine.currentTime)
        reporter = nil
        stopPreviewEncoding()
        Task {
            phase = .preparing
            do {
                // 列表接口的条目不含章节，取一次完整详情。
                let full = (try? await client?.item(id: episode.id)) ?? episode
                try await start(item: full)
                phase = .ready
                scheduleOrientation(app?.playerPreferences.orientationOnSwitch ?? .unchanged)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 章节

    /// 普通章节（不含 Emby 片头 / 片尾标记），附带其在原始数组中的序号（章节图片按序号寻址）。
    var chapters: [(index: Int, chapter: MediaChapter)] {
        (item?.chapters ?? []).enumerated()
            .filter { $0.element.marker == .chapter }
            .map { (index: $0.offset, chapter: $0.element) }
    }

    func chapterImageURL(index: Int, chapter: MediaChapter) -> URL? {
        guard let item else { return nil }
        return client?.chapterImageURL(itemID: item.id, index: index, chapter: chapter, maxWidth: 320)
    }

    // MARK: - 单集信息

    /// 单集信息面板的海报：单集用所属剧集的竖版海报（与 Android 一致），其余用条目自身的主图。
    var posterURL: URL? {
        guard let item else { return nil }
        if item.kind == .episode, let seriesID = item.seriesID {
            return client?.primaryImageURL(itemID: seriesID, maxWidth: 300)
        }
        return app?.imageURL(for: item, kind: .primary, maxWidth: 300)
    }

    /// 当前条目的演职人员（单集信息面板）。失败只记日志，面板不显示该分区，不影响播放。
    func loadPeople() async -> [ItemDetails.Person] {
        guard let client, let item else { return [] }
        do {
            return try await client.itemDetails(id: item.id).people
        } catch {
            Log.player.error("演职人员加载失败：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func personImageURL(_ person: ItemDetails.Person) -> URL? {
        client?.personImageURL(person, maxWidth: 240)
    }

    func episodeImageURL(_ episode: MediaItem) -> URL? {
        app?.imageURL(for: episode, kind: .primary, maxWidth: 320)
    }

    // MARK: - 拖动预览

    /// 直放的单文件直接本地抽帧；HLS 在首次拖动时向服务器另取一路低码率流，不与主播放共享转码会话。
    private func configurePreview(for stream: ResolvedStream, item: MediaItem) {
        stopPreviewEncoding()
        let isPlaylist = stream.url.pathExtension.lowercased() == "m3u8"
        // KSPlayer 直放的多为系统框架打不开的容器（MKV 等），本地抽帧不可用，改用服务器预览流。
        let container = stream.mediaSource.container?.split(separator: ",").first.map { String($0).lowercased() } ?? ""
        let systemReadable = controller.engine.kind == .avFoundation || ["mp4", "m4v", "mov"].contains(container)
        if stream.method == .directPlay, !isPlaylist, systemReadable {
            controller.scrubPreview.configure(.file(stream.url), allowsSweep: previewAllowsSweep(stream.url))
            return
        }
        guard let app, let client else {
            controller.scrubPreview.configure(nil)
            return
        }
        let resolver = app.playbackResolver
        let mediaSourceID = stream.mediaSource.id
        controller.scrubPreview.configure(allowsSweep: previewAllowsSweep(nil)) { [weak self] in
            do {
                let preview = try await resolver.resolvePreview(item: item, client: client, mediaSourceID: mediaSourceID)
                guard let self, self.item?.id == item.id, !self.closed else {
                    if let session = preview.playSessionID { try? await client.stopActiveEncodings(playSessionID: session) }
                    return nil
                }
                if preview.method == .transcode { self.previewPlaySessionID = preview.playSessionID }
                let previewIsPlaylist = preview.url.pathExtension.lowercased() == "m3u8"
                return preview.method == .directPlay && !previewIsPlaylist ? .file(preview.url) : .stream(preview.url)
            } catch {
                Log.player.info("预览流不可用：\(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// 预览能否在后台预生成整片网格：本地文件总是可以；网络片源在计费网络（蜂窝 / 低数据模式）下不额外下载关键帧。
    private func previewAllowsSweep(_ url: URL?) -> Bool {
        if url?.isFileURL == true { return true }
        return app.map { !$0.network.isMetered } ?? false
    }

    private func stopPreviewEncoding() {
        guard let session = previewPlaySessionID, let client else { return }
        previewPlaySessionID = nil
        Task { try? await client.stopActiveEncodings(playSessionID: session) }
    }

    // MARK: - 截图

    func captureScreenshot() {
        Task {
            guard let image = await controller.engine.captureFrame() else {
                controller.flash("截图失败", symbol: "exclamationmark.triangle")
                return
            }
            if let preferences = app?.playerPreferences, preferences.screenshotSavesToPhotos {
                guard let data = ScreenshotSaver.encode(image, format: preferences.screenshotFormat, quality: preferences.screenshotQuality) else {
                    controller.flash("截图编码失败", symbol: "exclamationmark.triangle")
                    return
                }
                let saved = await ScreenshotSaver.saveToPhotos(data)
                controller.flash(saved ? "已保存到相册" : "无法保存到相册，请在系统设置中允许添加照片",
                                 symbol: saved ? "checkmark.circle" : "exclamationmark.triangle")
                return
            }
            screenshot = image
            controller.touchControls()
        }
    }

    /// 分享截图时按设置的格式与质量编码。
    func encodedScreenshot() -> Data? {
        guard let screenshot, let preferences = app?.playerPreferences else { return nil }
        return ScreenshotSaver.encode(screenshot, format: preferences.screenshotFormat, quality: preferences.screenshotQuality)
    }

    var screenshotFileExtension: String { app?.playerPreferences.screenshotFormat.fileExtension ?? "jpg" }

    // MARK: - 播放循环

    /// 每秒一次：上报心跳、自动跳过片头、弹出下一集、同步「正在播放」。
    /// 设置睡眠定时；nil 关闭。
    func setSleepTimer(minutes: Int?) {
        sleepDeadline = minutes.map { Date.now.addingTimeInterval(TimeInterval($0 * 60)) }
        controller.flash(minutes.map { "\($0) 分钟后暂停播放" } ?? "已关闭睡眠定时", symbol: minutes == nil ? "moon" : "moon.zzz.fill")
    }

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

        // 转码流偶发起播失败（服务器在新位置的转码尚未就绪，分片请求出错，如 CoreMedia -16046）：
        // 自动从当前位置重新请求一次；再失败才按系统内核失败处理。
        if case .failed(let message) = engine.status {
            if stream?.method == .transcode, !autoRetriedFailure {
                autoRetriedFailure = true
                Log.player.error("转码流播放失败，自动重试一次：\(message, privacy: .public)")
                retryAfterFailure()
                return
            }
            if fallBackToKSPlayerIfNeeded(after: .error, detail: message) { return }
        } else if let issue = (engine as? any VideoDecodeDiagnosing)?.videoDecodeIssue,
                  fallBackToKSPlayerIfNeeded(after: .noVideoOutput(width: stream?.mediaSource.videoStream?.width), detail: issue) {
            return
        }
        if engine.status == .playing { autoRetriedFailure = false }

        // 播放到结尾立即发送 Stopped（位置 = 片长），服务器据此标记已看，不必等用户关闭播放器。
        if engine.status == .ended, !endedReported {
            endedReported = true
            traktStop()
            reporter?.stop(position: engine.duration > 0 ? engine.duration : position)
        } else if engine.status != .ended, endedReported, controller.isPlaying {
            // 结束后又开始播放（重播 / 拖回前面）：开启新的上报会话。
            endedReported = false
            restartReporting(at: position)
        } else {
            reporter?.tick(position: position, isPaused: isPaused)
            // Trakt：开始播放后 start，暂停 / 继续时切换 pause / start。
            if engine.status == .playing || engine.status == .paused, traktPaused != isPaused {
                traktPaused = isPaused
                traktReport(isPaused ? .pause : .start)
            }
        }

        if let sleepDeadline, Date.now >= sleepDeadline {
            self.sleepDeadline = nil
            engine.pause()
            controller.showMessage("睡眠定时已到，已暂停播放", symbol: "moon.zzz.fill", duration: .seconds(4))
        }
        autoSkipIfNeeded()
        preloadNextIfNeeded(position: position, duration: engine.duration)
        if let pendingOrientation, engine.videoSize != .zero {
            self.pendingOrientation = nil
            applyOrientation(pendingOrientation)
        }

        if let next = nextEpisode, shouldPresentUpNext(position: position, duration: engine.duration, ended: engine.status == .ended) {
            controller.presentUpNext(
                .init(
                    title: partPosition.map { "第 \($0.index + 1) 段 · \(next.name)" }
                        ?? next.episodeLabel.map { "\($0) · \(next.name)" } ?? next.name,
                    subtitle: next.seriesName,
                    imageURL: app?.imageURL(for: next, kind: .primary, maxWidth: 480),
                    countdown: nil,
                    heading: partPosition == nil ? "下一集" : "下一段"
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

    private func traktReport(_ action: TraktScrobble.Action) {
        guard let item, let app else { return }
        app.trakt.scrobble(action, item: item, position: controller.engine.currentTime, duration: controller.engine.duration)
    }

    /// 本条目已 start 过才发 stop，避免重复。
    private func traktStop() {
        guard traktPaused != nil else { return }
        traktReport(.stop)
        traktPaused = nil
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

    // MARK: - 自动跳过 / 预加载 / 方向

    /// 自动跳过片头：开启「即将跳过」提示时先提示 3 秒（期间拖走即取消），否则立即跳过。
    private func autoSkipIfNeeded() {
        guard let preferences = app?.playerPreferences, preferences.autoSkipIntro else { return }
        if let pending = pendingSkip {
            guard controller.activeSkippableSegment == pending.segment else {
                pendingSkip = nil
                return
            }
            if Date.now >= pending.at {
                pendingSkip = nil
                controller.skip(pending.segment)
            }
            return
        }
        guard let segment = controller.activeSkippableSegment, segment.kind == .intro, !autoSkipped.contains(segment) else { return }
        autoSkipped.insert(segment)
        if preferences.hintBeforeSkip {
            pendingSkip = (segment, Date.now.addingTimeInterval(3))
            controller.showMessage("即将跳过片头", symbol: "forward.end", duration: .seconds(3))
        } else {
            controller.skip(segment)
        }
    }

    /// 「预加载下一集」：进度超过阈值后请求下一集的播放信息，并预先请求一次码流地址，
    /// 让服务器提前打开文件 / 启动转码；切到下一集时直接使用。
    private func preloadNextIfNeeded(position: TimeInterval, duration: TimeInterval) {
        guard let app, let server, let client, let next = nextEpisode, partPosition == nil,
              preloadTask == nil, preloaded?.itemID != next.id, duration > 0 else { return }
        let threshold = app.playerPreferences.preloadNextPercent
        guard threshold > 0, position / duration * 100 >= Double(threshold) else { return }
        let capabilities = app.effectivePlaybackCapabilities
        let resolver = app.playbackResolver
        let startTime = resumePosition(for: next)
        let versionPreference = app.libraryPreferences.preferredVersion
        preloadTask = Task { [weak self] in
            defer { self?.preloadTask = nil }
            guard let stream = try? await resolver.resolve(
                item: next, server: server, client: client, capabilities: capabilities,
                versionPreference: versionPreference, startTime: startTime
            ), !Task.isCancelled else { return }
            // 只取开头一小段：HLS 取主播放列表即触发转码，直放文件取前 1 KB 预热连接与服务器文件句柄。
            var request = URLRequest(url: stream.url)
            if stream.method == .directPlay { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
            _ = try? await URLSession.shared.data(for: request)
            guard let self, !Task.isCancelled, self.nextEpisode?.id == next.id else { return }
            self.preloaded = (next.id, stream)
            self.isNextPreloaded = true
        }
    }

    /// 未使用的预加载码流：通知服务器结束其转码。
    private func discardPreloaded() {
        guard let preloaded else { return }
        self.preloaded = nil
        isNextPreloaded = false
        if preloaded.stream.method == .transcode, let session = preloaded.stream.playSessionID, let client {
            Task { try? await client.stopActiveEncodings(playSessionID: session) }
        }
    }

    private func scheduleOrientation(_ orientation: PlayerOrientation) {
        if orientation == .followVideo, controller.engine.videoSize == .zero {
            pendingOrientation = orientation
        } else {
            applyOrientation(orientation)
        }
    }

    private func applyOrientation(_ orientation: PlayerOrientation) {
        #if os(iOS)
        OrientationController.apply(orientation, videoSize: controller.engine.videoSize)
        #endif
    }

    // MARK: - 前后台

    #if os(iOS)
    /// 切后台：画中画中（或将自动进入画中画）不处理；否则按设置继续播放声音或暂停。回前台按设置继续播放。
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
    }

    private func didEnterBackground() {
        guard let preferences = app?.playerPreferences, !closed else { return }
        PlayerBrightness.leave()
        if controller.isPictureInPictureActive { return }
        // 即将自动进入画中画：此时小窗还没启动（isPictureInPictureActive 仍为 false），不能当作普通切后台暂停。
        // 系统内核用 AVPlayerLayer，KSPlayer 用其 AVSampleBufferDisplayLayer 内容源。
        let engine = controller.engine
        let canAutoPictureInPicture = AVPictureInPictureController.isPictureInPictureSupported()
            && (engine.supportsLayerPictureInPicture
                || (engine as? any EnginePictureInPictureProviding)?.pictureInPictureController != nil)
        // 已暂停时不会自动进入（见 `PlayerSurfaceHost.updateAutomaticPictureInPicture`），按普通切后台处理。
        if preferences.autoPictureInPicture, controller.isPlaying, canAutoPictureInPicture {
            return
        }
        if preferences.backgroundAudio {
            controller.setVideoDetached(true)
        } else if controller.isPlaying {
            controller.engine.pause()
            pausedForBackground = true
        }
    }

    private func willEnterForeground() {
        guard let preferences = app?.playerPreferences, !closed else { return }
        controller.setVideoDetached(false)
        if app?.pictureInPictureSession !== self { PlayerBrightness.enter(preferences) }
        if pausedForBackground {
            pausedForBackground = false
            if preferences.resumeOnForeground { controller.engine.play() }
        }
    }
    #endif

    /// 换成指定内核（当前已是该内核时不重建）。
    private func useEngine(_ engine: PlaybackEngineChoice.Engine) {
        let kind: PlaybackEngineKind = switch engine {
        case .system: .avFoundation
        case .ksPlayer: .ksPlayer
        }
        guard controller.engine.kind != kind else { return }
        switch engine {
        case .system: controller.replaceEngine(AVPlayerEngine())
        case .ksPlayer: controller.replaceEngine(makeKSPlayerEngine())
        }
    }

    /// KSPlayer 备选内核：按设置配置解码方式与软解线程。
    private func makeKSPlayerEngine() -> KSPlayerEngine {
        let engine = KSPlayerEngine()
        if let preferences = app?.playerPreferences {
            engine.configuration.hardwareDecoding = preferences.decodeMode == .hardware
            engine.configuration.decodeThreads = preferences.softwareDecodeThreads
            engine.configuration.dolbyPassthrough = preferences.enableAtmos
        }
        return engine
    }

    private func shouldPresentUpNext(position: TimeInterval, duration: TimeInterval, ended: Bool) -> Bool {
        if ended { return true }
        if controller.activeOutro != nil { return true }
        let hasOutro = controller.segments.contains { $0.kind == .outro }
        return !hasOutro && duration > 0 && duration - position <= Self.upNextFallbackLead
    }
}
