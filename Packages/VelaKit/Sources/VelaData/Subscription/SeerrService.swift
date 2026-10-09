import Foundation
import Observation
import VelaCore
import VelaNetwork

/// Seerr（Jellyseerr / Overseerr）连接与请求。与 Android 版一致，每台媒体服务器单独连接（Seerr 用媒体服务器账号登录）。
///
/// 地址与版本存 UserDefaults；会话 Cookie 存 Keychain；密码不保存（会话失效后需重新连接）。
@MainActor
@Observable
public final class SeerrService {
    public struct Connection: Equatable, Sendable {
        public var url: String
        public var version: String?
        public var username: String
    }

    /// 已连接的服务器（媒体服务器 id → 连接信息）。
    public private(set) var connections: [String: Connection] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    private static let storageKey = "seerr.connections"

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: StoredConnection].self, from: data) {
            connections = stored.compactMapValues { stored in
                // Cookie 丢失（例如从备份恢复到新设备）时视为未连接。
                guard ((try? keychain.string(for: Self.cookieAccount(stored.url))) ?? nil) != nil else { return nil }
                return Connection(url: stored.url, version: stored.version, username: stored.username)
            }
        }
    }

    private struct StoredConnection: Codable {
        var url: String
        var version: String?
        var username: String
    }

    private static func cookieAccount(_ url: String) -> String { "seerr-cookie:\(url)" }

    public func connection(for serverID: String?) -> Connection? {
        serverID.flatMap { connections[$0] }
    }

    /// 登录并读取当前用户确认可用后保存。`mediaServerURL` 为当前媒体服务器地址（Seerr 尚未配置媒体服务器时使用）。
    public func connect(serverID: String, url rawURL: String, username: String, password: String, mediaServerURL: String) async throws {
        let anonymous = try SeerrClient(baseURL: rawURL)
        let status = try await anonymous.status()
        let cookie = try await anonymous.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password, mediaServerURL: mediaServerURL)
        let normalized = anonymous.baseURL.absoluteString
        _ = try await SeerrClient(baseURL: normalized, cookie: cookie).currentUser()
        try keychain.set(cookie, for: Self.cookieAccount(normalized))
        connections[serverID] = Connection(url: normalized, version: status.version, username: username.trimmingCharacters(in: .whitespaces))
        save()
    }

    public func disconnect(serverID: String) {
        guard let connection = connections.removeValue(forKey: serverID) else { return }
        // 其他服务器仍在使用同一 Seerr 时保留会话。
        if !connections.values.contains(where: { $0.url == connection.url }) {
            try? keychain.remove(Self.cookieAccount(connection.url))
        }
        save()
    }

    /// 已连接服务器的客户端；会话失效（401 / 403）时界面提示重新连接。
    public func client(for serverID: String?) throws -> SeerrClient? {
        guard let connection = connection(for: serverID), let cookie = try keychain.string(for: Self.cookieAccount(connection.url)) else { return nil }
        return try SeerrClient(baseURL: connection.url, cookie: cookie)
    }

    private func save() {
        let stored = connections.mapValues { StoredConnection(url: $0.url, version: $0.version, username: $0.username) }
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.storageKey)
    }
}
