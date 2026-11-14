import Foundation
import VelaCore
import VelaNetwork

/// 添加服务器：探测地址 → 识别类型 → 用户名密码登录 → 生成 `SavedServer`。不负责持久化。
public struct ServerLoginService: Sendable {
    public struct Output: Sendable {
        public var server: SavedServer
        public var accessToken: String
    }

    private let identity: ClientIdentity

    public init(identity: ClientIdentity) {
        self.identity = identity
    }

    public func login(address: String, username: String, password: String, note: String? = nil) async throws -> Output {
        let probe = try await MediaServerProbe.probe(address)
        let auth = try await MediaServerProbe.authenticate(
            baseURL: probe.baseURL,
            kind: probe.kind,
            username: username,
            password: password,
            identity: identity
        )
        guard let instanceID = probe.info.id ?? auth.serverID ?? auth.user.serverID else {
            throw APIError.decoding("服务器未返回实例 id")
        }
        let server = SavedServer(
            serverInstanceID: instanceID,
            serverName: probe.info.serverName ?? probe.kind.displayName,
            kind: probe.kind,
            username: auth.user.name,
            userID: auth.user.id,
            note: note,
            lines: [ServerLine(url: probe.baseURL)]
        )
        return Output(server: server, accessToken: auth.accessToken)
    }

    public func loginNavidrome(address: String, username: String, password: String, note: String?,
                               useAPIKey: Bool = false) async throws -> Output {
        let url = try NavidromeClient.address(address)
        // Subsonic 不提供稳定的实例 ID；首版单线路，以规范化基址识别同一账号。
        let instance = "navidrome:" + url.absoluteString
        let client = NavidromeClient(accountID: "", baseURL: url, username: username, password: useAPIKey ? "" : password,
                                     apiKey: useAPIKey ? password : nil)
        try await client.ping()
        let resolved = try await (useAPIKey ? client.tokenUsername() : client.user().username)
        var server = SavedServer(serverInstanceID: instance, serverName: "Navidrome", kind: .navidrome,
                                 username: resolved, userID: resolved, note: note, lines: [ServerLine(url: url)],
                                 autoRouteEnabled: false, preferStrmOriginalPath: false)
        server.usesNavidromeAPIKey = useAPIKey
        return Output(server: server, accessToken: password)
    }
}
