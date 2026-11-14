import Foundation
import Observation
import VelaCore
import VelaNetwork

/// 已登录服务器的唯一真相源：服务器列表落盘为 JSON（Application Support），凭据存 Keychain。
///
/// 只在主线程读写；网络请求通过 `client(for:)` 拿到的值类型 client 在任意线程执行。
@MainActor
@Observable
public final class ServerStore {
    public private(set) var servers: [SavedServer] = []
    public private(set) var activeServerID: String?
    /// 最近一次持久化失败的原因；界面可提示，但不阻断内存中的状态。
    public private(set) var persistenceError: String?

    public let identity: ClientIdentity
    /// client 请求遇到连接层失败时回调（服务器 id、请求的线路地址），由多线路路由器设置。
    /// 需在创建任何 client 之前设置；已缓存的 client 不会更新。
    @ObservationIgnored public var transportFailureHandler: (@Sendable (_ serverID: String, _ baseURL: URL) -> Void)?
    private let keychain: KeychainStore
    private let fileURL: URL

    private struct Snapshot: Codable {
        var servers: [SavedServer]
        var activeServerID: String?
    }

    public init(identity: ClientIdentity, keychain: KeychainStore = KeychainStore(), directory: URL? = nil) {
        self.identity = identity
        self.keychain = keychain
        let base = directory ?? URL.applicationSupportDirectory.appending(path: "Vela", directoryHint: .isDirectory)
        self.fileURL = base.appending(path: "servers.json")
        load()
    }

    public var activeServer: SavedServer? {
        servers.first { $0.id == activeServerID } ?? servers.first
    }

    /// 新增或覆盖同一身份（服务器实例 + 用户）的账号，并设为当前服务器。
    public func upsert(_ server: SavedServer, accessToken: String) throws {
        try keychain.set(accessToken, for: server.id)
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            // 重新登录同一账号时保留用户已有的线路与偏好，只合并新地址。
            var merged = servers[index]
            for line in server.lines where !merged.lines.contains(where: { $0.url == line.url }) {
                merged.lines.append(line)
            }
            merged.serverName = server.serverName
            merged.kind = server.kind
            merged.usesNavidromeAPIKey = server.usesNavidromeAPIKey
            merged.lastUsedAt = .now
            servers[index] = merged
        } else {
            servers.append(server)
        }
        activeServerID = server.id
        save()
    }

    public func update(_ server: SavedServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        save()
    }

    public func remove(_ serverID: String) {
        servers.removeAll { $0.id == serverID }
        try? keychain.remove(serverID)
        if activeServerID == serverID { activeServerID = servers.first?.id }
        save()
    }

    public func activate(_ serverID: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].lastUsedAt = .now
        activeServerID = serverID
        save()
    }

    // MARK: - 线路

    /// 切换当前线路；线路不存在时忽略。
    public func setActiveLine(serverID: String, lineID: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }),
              servers[index].lines.contains(where: { $0.id == lineID }),
              servers[index].activeLineID != lineID else { return }
        servers[index].activeLineID = lineID
        save()
    }

    /// 新增线路；同一地址已存在时返回已有线路。
    @discardableResult
    public func addLine(serverID: String, url: URL, name: String) -> ServerLine? {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return nil }
        if let existing = servers[index].lines.first(where: { $0.url == url }) { return existing }
        let line = ServerLine(name: name.trimmingCharacters(in: .whitespaces), url: url)
        servers[index].lines.append(line)
        save()
        return line
    }

    public func renameLine(serverID: String, lineID: String, name: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }),
              let lineIndex = servers[index].lines.firstIndex(where: { $0.id == lineID }) else { return }
        servers[index].lines[lineIndex].name = name.trimmingCharacters(in: .whitespaces)
        save()
    }

    /// 删除线路。至少保留一条；删除当前线路时切到剩余的第一条。
    public func removeLine(serverID: String, lineID: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }),
              servers[index].lines.count > 1 else { return }
        servers[index].lines.removeAll { $0.id == lineID }
        if servers[index].activeLineID == lineID {
            servers[index].activeLineID = servers[index].lines[0].id
        }
        save()
    }

    /// 为指定服务器构造 API client。token 缺失（例如 Keychain 被清空）时抛出未授权，界面应引导重新登录。
    public func client(for server: SavedServer) throws -> MediaServerClient {
        guard server.kind != .navidrome, let token = try keychain.string(for: server.id) else { throw APIError.unauthorized }
        var onFailure: (@Sendable (URL) -> Void)?
        if let handler = transportFailureHandler {
            let serverID = server.id
            onFailure = { url in handler(serverID, url) }
        }
        return MediaServerClient(
            serverID: server.id,
            baseURL: server.baseURL,
            kind: server.kind,
            userID: server.userID,
            accessToken: token,
            identity: identity,
            http: HTTPClient(onTransportFailure: onFailure)
        )
    }

    public func navidromeClient(for server: SavedServer) throws -> NavidromeClient {
        guard server.kind == .navidrome, let password = try keychain.string(for: server.id) else {
            throw NavidromeError.authentication
        }
        let apiKey = server.usesNavidromeAPIKey == true ? password : nil
        return NavidromeClient(accountID: server.id, baseURL: server.baseURL, username: server.username,
                               password: apiKey == nil ? password : "", apiKey: apiKey)
    }

    public func client(forServerID serverID: String) throws -> MediaServerClient {
        guard let server = servers.first(where: { $0.id == serverID }) else { throw APIError.unauthorized }
        return try client(for: server)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            servers = snapshot.servers
            activeServerID = snapshot.activeServerID
        } catch {
            persistenceError = error.localizedDescription
            Log.data.error("服务器列表解析失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Snapshot(servers: servers, activeServerID: activeServerID))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            Log.data.error("服务器列表保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
