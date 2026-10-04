import Foundation

/// 媒体服务器类型。Jellyfin 由 Emby 分叉而来，接口大体一致，差异集中在认证头与 token 参数名。
public enum MediaServerKind: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case emby

    public var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        }
    }
}

/// 同一台服务器的一个可达地址（局域网 / 公网 / 备用）。token 绑定在 `SavedServer` 上，与线路无关。
public struct ServerLine: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 用户命名；为空时界面按局域网 / 公网自动命名。
    public var name: String
    public var url: URL

    public init(id: String = UUID().uuidString, name: String = "", url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

    public var isLAN: Bool { LineRouting.isLANHost(url.host() ?? "") }
}

/// 已登录的服务器账号。身份是「服务器实例 id + 用户 id」，不是 URL：同一台服务器换地址仍是同一账号。
///
/// 访问 token 不在此结构中，而是按 `id` 存在 Keychain，避免随 JSON 落盘。
public struct SavedServer: Codable, Hashable, Sendable, Identifiable {
    /// `"\(serverInstanceID)|\(userID)"`，见 `SavedServer.makeID`。
    public var id: String
    public var serverInstanceID: String
    public var serverName: String
    public var kind: MediaServerKind
    public var username: String
    public var userID: String
    /// 用户备注；非空时替换服务器自报的名称显示。
    public var note: String?
    public var lines: [ServerLine]
    public var activeLineID: String
    /// 私密服务器：进入前需要设备认证，解锁状态只保存在进程内存中。
    public var isPrivate: Bool
    /// 网络变化时是否自动在局域网 / 公网线路之间切换。
    public var autoRouteEnabled: Bool
    /// STRM 条目的 Path 为 http(s) 时直接播放原始地址，而不是走服务器串流接口。
    public var preferStrmOriginalPath: Bool
    public var lastUsedAt: Date

    public init(
        serverInstanceID: String,
        serverName: String,
        kind: MediaServerKind,
        username: String,
        userID: String,
        note: String? = nil,
        lines: [ServerLine],
        activeLineID: String? = nil,
        isPrivate: Bool = false,
        autoRouteEnabled: Bool = true,
        preferStrmOriginalPath: Bool = true,
        lastUsedAt: Date = .now
    ) {
        precondition(!lines.isEmpty, "SavedServer 至少需要一条线路")
        self.id = Self.makeID(serverInstanceID: serverInstanceID, userID: userID)
        self.serverInstanceID = serverInstanceID
        self.serverName = serverName
        self.kind = kind
        self.username = username
        self.userID = userID
        self.note = note
        self.lines = lines
        self.activeLineID = activeLineID ?? lines[0].id
        self.isPrivate = isPrivate
        self.autoRouteEnabled = autoRouteEnabled
        self.preferStrmOriginalPath = preferStrmOriginalPath
        self.lastUsedAt = lastUsedAt
    }

    public static func makeID(serverInstanceID: String, userID: String) -> String {
        "\(serverInstanceID)|\(userID)"
    }

    public var displayName: String {
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        return serverName
    }

    /// 当前用于 API 与播放的线路；`activeLineID` 失效时回退到第一条。
    public var activeLine: ServerLine {
        lines.first { $0.id == activeLineID } ?? lines[0]
    }

    public var baseURL: URL { activeLine.url }
}
