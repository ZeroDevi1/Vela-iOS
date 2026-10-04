import Foundation
import VelaCore

/// 本机在服务器上的身份。`deviceID` 必须稳定：服务器按它区分会话与设备，变化会让管理面板里堆积重复设备。
public struct ClientIdentity: Sendable, Hashable {
    public var clientName: String
    public var deviceName: String
    public var deviceID: String
    public var version: String

    public init(clientName: String = "Vela", deviceName: String, deviceID: String, version: String) {
        self.clientName = clientName
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.version = version
    }
}

/// `Authorization` / `X-Emby-Authorization` 头。Jellyfin 10.8+ 用 `MediaBrowser` scheme，Emby 用 `Emby`。
public struct AuthorizationHeader: Sendable {
    public var kind: MediaServerKind?
    public var identity: ClientIdentity
    public var accessToken: String?

    public init(kind: MediaServerKind?, identity: ClientIdentity, accessToken: String? = nil) {
        self.kind = kind
        self.identity = identity
        self.accessToken = accessToken
    }

    public var value: String {
        let scheme = kind == .emby ? "Emby" : "MediaBrowser"
        var fields = [
            "Client=\"\(Self.escape(identity.clientName))\"",
            "Device=\"\(Self.escape(identity.deviceName))\"",
            "DeviceId=\"\(Self.escape(identity.deviceID))\"",
            "Version=\"\(Self.escape(identity.version))\""
        ]
        if let token = accessToken, !token.isEmpty {
            fields.append("Token=\"\(token)\"")
        }
        return scheme + " " + fields.joined(separator: ", ")
    }

    /// 两个头都带上：Jellyfin 认 `Authorization`，Emby 与旧版 Jellyfin 认 `X-Emby-Authorization`。
    public var headers: [String: String] {
        var result = ["Authorization": value, "X-Emby-Authorization": value]
        if let token = accessToken, !token.isEmpty {
            result["X-Emby-Token"] = token
        }
        return result
    }

    /// 设备名含引号或非 ASCII 字符时服务器解析会失败，统一做百分号编码。
    private static func escape(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: " -_.()"))) ?? raw
    }
}

extension MediaServerKind {
    /// 拼在媒体 URL 上的 token 参数名：AVPlayer 等外部组件无法注入请求头时使用。
    public var tokenQueryName: String { self == .emby ? "api_key" : "ApiKey" }
}
