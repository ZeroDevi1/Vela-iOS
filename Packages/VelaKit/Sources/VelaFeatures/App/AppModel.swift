import Foundation
import Observation
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork
import VelaPlayer

/// 应用级依赖容器。由 App 入口创建一次，通过 SwiftUI Environment 注入；功能页面只从这里取服务，不自行创建单例。
@MainActor
@Observable
public final class AppModel {
    public let servers: ServerStore
    public let privacy: PrivacyGuard
    public let loginService: ServerLoginService
    public let playbackResolver = PlaybackResolver()
    public let playerPreferences = PlayerPreferences()
    public let libraryPreferences = LibraryPreferences()
    /// 多线路自动路由。
    public let lineRouter: LineRouter
    /// TMDB 发现 / 目录。
    public let catalog = CatalogService()
    /// MoviePilot 订阅与日历。
    public let subscriptions = SubscriptionService()
    /// Seerr（Jellyseerr / Overseerr）请求，每台媒体服务器单独连接。
    public let seerr = SeerrService()
    /// Trakt 同步。
    public let trakt = TraktService()
    /// 离线下载。
    public let downloads = DownloadManager()
    /// 网络状态：无网络时首页回退到已下载内容。
    public let network = NetworkStatus()
    /// 启动时探测一次；外接显示器变化导致的 HDR 能力变化在播放前重新探测。
    public private(set) var capabilities: PlaybackCapabilities

    /// iPhone / iPad 上全屏呈现的播放请求；macOS 使用独立窗口，不经过此属性。
    public var presentedPlayback: PlaybackRequest?
    /// 画中画中的播放会话：播放页收起后由这里持有，使播放继续；从小窗恢复时交还给重新呈现的播放页。
    @ObservationIgnored var pictureInPictureSession: PlayerSession?

    /// 发起新的播放：若画中画正在播放其他条目，先结束它（小窗关闭回调会结束会话并上报进度）。
    public func present(_ request: PlaybackRequest) {
        if let session = pictureInPictureSession, session.request.id != request.id {
            session.controller.stopPictureInPicture()
        }
        presentedPlayback = request
    }

    /// 服务器 id → (线路地址, client)。线路切换后地址变化，缓存随之失效。
    @ObservationIgnored private var clientCache: [String: (baseURL: URL, client: MediaServerClient)] = [:]

    public init() {
        let identity = DeviceIdentity.current()
        let servers = ServerStore(identity: identity)
        let router = LineRouter(store: servers)
        // 必须在创建任何 client 之前设置，失败回调才会进入路由器。
        servers.transportFailureHandler = { [weak router] serverID, baseURL in
            router?.reportTransportFailure(serverID: serverID, baseURL: baseURL)
        }
        self.servers = servers
        self.lineRouter = router
        self.privacy = PrivacyGuard()
        self.loginService = ServerLoginService(identity: identity)
        self.capabilities = PlaybackCapabilityProbe.current()
        router.start()
        downloads.clientProvider = { [weak self] serverID in self?.client(forServerID: serverID) }
        // 统计图片磁盘缓存并按上限淘汰；之后写入时累计维护，不再反复枚举目录。
        Task.detached(priority: .background) { await ImagePipeline.shared.trimDiskCache() }
    }

    /// 返回服务器对应的 client，并按「服务器 + 当前线路」缓存，避免每次取图片地址都读 Keychain。
    public func client(forServerID serverID: String) -> MediaServerClient? {
        // 每张卡片渲染都会调用：只做查找与 URL 比较，不拼接字符串、不读 Keychain。
        guard let server = servers.servers.first(where: { $0.id == serverID }) else { return nil }
        if let cached = clientCache[serverID], cached.baseURL == server.baseURL { return cached.client }
        guard let client = try? servers.client(for: server) else { return nil }
        clientCache[serverID] = (server.baseURL, client)
        return client
    }

    public var activeClient: MediaServerClient? {
        servers.activeServer.flatMap { client(forServerID: $0.id) }
    }

    /// 当前服务器是否可以展示内容：私密服务器必须在本进程内解锁过。
    public var isActiveServerAccessible: Bool {
        guard let server = servers.activeServer else { return false }
        return !server.isPrivate || privacy.isUnlocked(server.id)
    }

    public func refreshCapabilities() {
        capabilities = PlaybackCapabilityProbe.current()
    }

    /// 发给服务器的能力：设备实测能力叠加音频设置（「原生音频」关闭时下混为立体声，「杜比全景声」关闭时不直通 E-AC3）。
    public var effectivePlaybackCapabilities: PlaybackCapabilities {
        var caps = capabilities
        if !playerPreferences.nativeAudio { caps.maxAudioChannels = 2 }
        caps.supportsEAC3 = playerPreferences.enableAtmos
        return caps
    }

    /// 跨服务器聚合（目录匹配、聚合继续观看）的数据源。
    ///
    /// 与 Android 版一致：私密服务器无论是否解锁都不参与聚合，只能切换为当前服务器后单独浏览，
    /// 避免其内容混入公共结果（例如解锁后忘记锁定、给他人演示搜索）。
    public var searchableSources: [FederatedSearchService.Source] {
        servers.servers.compactMap { server in
            guard !server.isPrivate, let client = client(forServerID: server.id) else { return nil }
            return .init(id: server.id, name: server.displayName, client: client)
        }
    }

    public func imageURL(for item: MediaItem, kind: MediaItem.ImageKind, maxWidth: Int) -> URL? {
        client(forServerID: item.serverID)?.imageURL(for: item, kind: kind, maxWidth: maxWidth)
    }
}

/// 一次播放请求。可编码，以便 macOS 用 `openWindow(value:)` 在新窗口中打开播放器。
public struct PlaybackRequest: Hashable, Codable, Identifiable, Sendable {
    public enum Target: Hashable, Codable, Sendable {
        case item(serverID: String, itemID: String)
        /// 直接播放 URL（调试 / 外部链接）。
        case url(URL)
    }

    /// 详情页预先选择的版本 / 音轨 / 字幕；nil 表示使用服务器默认。
    public struct Options: Hashable, Codable, Sendable {
        public var mediaSourceID: String?
        public var audioStreamIndex: Int?
        /// -1 表示关闭字幕。
        public var subtitleStreamIndex: Int?
        /// 忽略续播位置，从头播放。
        public var startFromBeginning: Bool
        /// 多段文件（CD1 / CD2 …）全部段的条目 id（按顺序）；从任意一段起播时，播放器据此衔接上一段 / 下一段。
        public var partIDs: [String]?
        /// `partIDs` 第一段（主条目）要播放的版本（媒体源 id）。多版本条目的分段只属于其中一个版本，
        /// 播放中从其它段回到第一段时继续用它；nil 表示按「视频首选版本」选择。
        public var partsSourceID: String?
        /// 指定起播位置（秒），例如从详情页章节卡进入；优先于续播位置与 `startFromBeginning`。
        public var startPosition: TimeInterval?

        public init(mediaSourceID: String? = nil, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
                    startFromBeginning: Bool = false, partIDs: [String]? = nil, partsSourceID: String? = nil,
                    startPosition: TimeInterval? = nil) {
            self.mediaSourceID = mediaSourceID
            self.audioStreamIndex = audioStreamIndex
            self.subtitleStreamIndex = subtitleStreamIndex
            self.startFromBeginning = startFromBeginning
            self.partIDs = partIDs
            self.partsSourceID = partsSourceID
            self.startPosition = startPosition
        }
    }

    public var id: String
    public var target: Target
    public var title: String
    public var options: Options

    public init(target: Target, title: String, options: Options = Options()) {
        self.target = target
        self.title = title
        self.options = options
        switch target {
        case .item(let serverID, let itemID): id = serverID + "/" + itemID
        case .url(let url): id = url.absoluteString
        }
    }

    public static func item(_ item: MediaItem, options: Options = Options()) -> PlaybackRequest {
        PlaybackRequest(target: .item(serverID: item.serverID, itemID: item.id), title: item.name, options: options)
    }
}
