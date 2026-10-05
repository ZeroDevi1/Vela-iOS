import Foundation
import VelaCore

/// Trakt API v2：设备码授权（适合电视 / 手机，无需内嵌网页）与 scrobble。
///
/// Client ID / Secret 由用户在 trakt.tv/oauth/applications 注册应用后填写，客户端不内置。
public struct TraktClient: Sendable {
    public enum TraktError: LocalizedError, Equatable {
        case pending
        case slowDown
        case expired
        case denied
        case unauthorized
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .pending: "等待在 Trakt 网站上确认授权"
            case .slowDown: "请求过于频繁"
            case .expired: "授权码已过期，请重新开始"
            case .denied: "授权被拒绝"
            case .unauthorized: "Trakt 授权已失效，请重新连接"
            case .http(let status): "Trakt 返回错误（HTTP \(status)）"
            }
        }
    }

    public struct DeviceCode: Sendable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: URL
        public var expiresIn: TimeInterval
        /// 轮询间隔（秒）。
        public var interval: TimeInterval
    }

    public struct Tokens: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date

        public var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
    }

    private let clientID: String
    private let clientSecret: String
    private let session: URLSession
    private static let base = URL(string: "https://api.trakt.tv")!

    public init(clientID: String, clientSecret: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
    }

    // MARK: - 授权

    public func requestDeviceCode() async throws -> DeviceCode {
        let object = try await post("oauth/device/code", ["client_id": clientID], token: nil)
        guard let code = object["device_code"] as? String, let user = object["user_code"] as? String,
              let urlString = object["verification_url"] as? String, let url = URL(string: urlString) else {
            throw TraktError.http(-1)
        }
        return DeviceCode(
            deviceCode: code, userCode: user, verificationURL: url,
            expiresIn: (object["expires_in"] as? NSNumber)?.doubleValue ?? 600,
            interval: (object["interval"] as? NSNumber)?.doubleValue ?? 5
        )
    }

    /// 轮询一次：用户尚未确认时抛 `.pending`。
    public func pollToken(deviceCode: String) async throws -> Tokens {
        do {
            let object = try await post("oauth/device/token", [
                "code": deviceCode, "client_id": clientID, "client_secret": clientSecret
            ], token: nil)
            return try Self.tokens(from: object)
        } catch TraktError.http(let status) {
            switch status {
            case 400: throw TraktError.pending
            case 429: throw TraktError.slowDown
            case 410: throw TraktError.expired
            case 418: throw TraktError.denied
            default: throw TraktError.http(status)
            }
        }
    }

    public func refresh(_ tokens: Tokens) async throws -> Tokens {
        let object = try await post("oauth/token", [
            "refresh_token": tokens.refreshToken, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"
        ], token: nil)
        return try Self.tokens(from: object)
    }

    private static func tokens(from object: [String: Any]) throws -> Tokens {
        guard let access = object["access_token"] as? String, let refresh = object["refresh_token"] as? String else {
            throw TraktError.http(-1)
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 7_776_000
        return Tokens(accessToken: access, refreshToken: refresh, expiresAt: .now.addingTimeInterval(expiresIn))
    }

    // MARK: - Scrobble

    public func scrobble(_ action: TraktScrobble.Action, item: MediaItem, progress: Double, accessToken: String) async throws {
        guard let body = TraktScrobble.body(for: item) else { return }
        var payload: [String: Any] = ["progress": (progress * 100).rounded() / 100]
        for (key, value) in body {
            // Trakt 的 tmdb / tvdb id 为整数，imdb 为字符串。
            let ids = value["ids"] ?? [:]
            payload[key] = ["ids": ids.mapValues { Int($0).map { $0 as Any } ?? $0 as Any }]
        }
        _ = try await post("scrobble/\(action.rawValue)", payload, token: accessToken)
    }

    // MARK: - 请求

    private func post(_ path: String, _ body: [String: Any], token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: Self.base.appending(path: path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TraktError.http(-1) }
        switch http.statusCode {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 401 where token != nil:
            throw TraktError.unauthorized
        case 409:
            // 重复 scrobble（例如连续两次 stop）：Trakt 视为已处理。
            return [:]
        default:
            throw TraktError.http(http.statusCode)
        }
    }
}
