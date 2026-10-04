import Foundation
import Observation
import VelaCore
import VelaData
import VelaNetwork
import VelaPlayer

/// 应用级依赖容器。由 App 入口创建一次，通过 SwiftUI Environment 注入；功能页面只从这里取服务，不自行创建单例。
@MainActor
@Observable
public final class AppModel {
    public let servers: ServerStore
    public let privacy: PrivacyGuard
    public let loginService: ServerLoginService
    public let searchService = FederatedSearchService()
    public let playbackResolver = PlaybackResolver()
    public let playerPreferences = PlayerPreferences()
    /// 启动时探测一次；外接显示器变化导致的 HDR 能力变化在播放前重新探测。
    public private(set) var capabilities: PlaybackCapabilities

    /// iPhone / iPad 上全屏呈现的播放请求；macOS 使用独立窗口，不经过此属性。
    public var presentedPlayback: PlaybackRequest?

    @ObservationIgnored private var clientCache: [String: (key: String, client: MediaServerClient)] = [:]

    public init() {
        let identity = DeviceIdentity.current()
        self.servers = ServerStore(identity: identity)
        self.privacy = PrivacyGuard()
        self.loginService = ServerLoginService(identity: identity)
        self.capabilities = PlaybackCapabilityProbe.current()
    }

    /// 返回服务器对应的 client，并按「服务器 + 当前线路」缓存，避免每次取图片地址都读 Keychain。
    public func client(forServerID serverID: String) -> MediaServerClient? {
        guard let server = servers.servers.first(where: { $0.id == serverID }) else { return nil }
        let key = server.id + "|" + server.baseURL.absoluteString
        if let cached = clientCache[serverID], cached.key == key { return cached.client }
        guard let client = try? servers.client(for: server) else { return nil }
        clientCache[serverID] = (key, client)
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

    /// 聚合搜索的数据源：排除未解锁的私密服务器，避免在搜索结果中泄露其内容。
    public var searchableSources: [FederatedSearchService.Source] {
        servers.servers.compactMap { server in
            guard !server.isPrivate || privacy.isUnlocked(server.id),
                  let client = client(forServerID: server.id) else { return nil }
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

        public init(mediaSourceID: String? = nil, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil, startFromBeginning: Bool = false) {
            self.mediaSourceID = mediaSourceID
            self.audioStreamIndex = audioStreamIndex
            self.subtitleStreamIndex = subtitleStreamIndex
            self.startFromBeginning = startFromBeginning
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
