import Foundation
import VelaCore

/// Jellyseerr / Overseerr 接口（`/api/v1`，与 Android `SeerrApiClient` 相同的端点）。
///
/// 登录用媒体服务器账号（`auth/jellyfin`，Emby 同样走这个端点）或 Seerr 本地账号（邮箱，`auth/local`），
/// 成功后服务器以 `connect.sid` Cookie 维持会话；之后的请求带上该 Cookie。会话不放进系统 Cookie 存储，
/// 由调用方保存在 Keychain。
public struct SeerrClient: Sendable {
    public enum SeerrError: LocalizedError {
        case invalidURL
        case credentialsRejected
        case sessionExpired
        case missingSessionCookie
        case http(Int, String?)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Seerr 地址无效，请填写 http(s):// 开头的地址"
            case .credentialsRejected: "用户名或密码错误"
            case .sessionExpired: "Seerr 登录已失效，请重新连接"
            case .missingSessionCookie: "Seerr 没有返回登录会话"
            case .http(let status, let message): message.map { "Seerr 返回错误（HTTP \(status)）：\($0)" } ?? "Seerr 返回错误（HTTP \(status)）"
            }
        }
    }

    /// 条目在 Seerr 中的状态（`MediaStatus`）。
    public enum MediaStatus: Int, Sendable {
        case unknown = 1, pending, processing, partiallyAvailable, available, blacklisted

        public var title: String {
            switch self {
            case .unknown: "未请求"
            case .pending: "等待审核"
            case .processing: "处理中"
            case .partiallyAvailable: "部分可用"
            case .available: "已可用"
            case .blacklisted: "已屏蔽"
            }
        }
    }

    public struct Status: Decodable, Sendable { public var version: String? }

    public struct User: Decodable, Sendable {
        public var id: Int
        public var displayName: String?
    }

    /// 条目详情中与请求有关的部分。
    public struct Title: Sendable {
        public struct Season: Identifiable, Sendable {
            public var number: Int
            public var name: String?
            public var status: MediaStatus
            public var id: Int { number }
        }

        public var tmdbID: Int
        public var mediaType: CatalogTitle.MediaType
        public var name: String
        public var posterPath: String?
        public var status: MediaStatus
        /// 只含正片季（不含特别篇第 0 季）。
        public var seasons: [Season]
    }

    /// 「我的请求」中的一条。
    public struct Request: Identifiable, Sendable {
        public var id: Int
        /// 1 待审核、2 已批准、3 已拒绝、4 失败、5 已完成。
        public var requestStatus: Int
        public var mediaStatus: MediaStatus
        public var tmdbID: Int?
        public var mediaType: CatalogTitle.MediaType?
        public var createdAt: Date?

        public var requestStatusTitle: String {
            switch requestStatus {
            case 1: "待审核"
            case 2: "已批准"
            case 3: "已拒绝"
            case 4: "失败"
            case 5: "已完成"
            default: "未知"
            }
        }
    }

    public let baseURL: URL
    private let cookie: String?
    private let session: URLSession

    /// - Parameter rawURL: Seerr 地址（可带或不带 `/api/v1`）。
    public init(baseURL rawURL: String, cookie: String? = nil) throws {
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api/v1") { text.removeLast("/api/v1".count) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.query == nil else { throw SeerrError.invalidURL }
        baseURL = url
        self.cookie = cookie
        let configuration = URLSessionConfiguration.ephemeral
        // 会话 Cookie 由调用方管理（Keychain），不进系统 Cookie 存储，也不自动发送。
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    // MARK: - 连接

    public func status() async throws -> Status {
        try await decode(Status.self, path: "status")
    }

    /// 登录并返回会话 Cookie。名称为邮箱时用 Seerr 本地账号，否则用媒体服务器账号；
    /// Seerr 尚未配置媒体服务器时需提供 `mediaServerURL`（已配置时服务器返回「hostname already configured」，去掉后重试）。
    public func signIn(username: String, password: String, mediaServerURL: String?) async throws -> String {
        if username.contains("@"), username.contains(".") {
            return try await signInRequest(path: "auth/local", body: ["email": username, "password": password])
        }
        var body = ["username": username, "password": password]
        if let mediaServerURL { body["hostname"] = mediaServerURL }
        do {
            return try await signInRequest(path: "auth/jellyfin", body: body)
        } catch SeerrError.http(500, let message) where message?.localizedCaseInsensitiveContains("hostname already configured") == true {
            body["hostname"] = nil
            return try await signInRequest(path: "auth/jellyfin", body: body)
        }
    }

    private func signInRequest(path: String, body: [String: String]) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.http(-1, nil) }
        if http.statusCode == 401 || http.statusCode == 403 { throw SeerrError.credentialsRejected }
        guard (200..<300).contains(http.statusCode) else { throw SeerrError.http(http.statusCode, Self.message(data)) }
        guard let cookie = Self.sessionCookie(http) else { throw SeerrError.missingSessionCookie }
        return cookie
    }

    /// 取 `connect.sid=…`（只保留名称与值，不带 Path / Expires 等属性）。
    static func sessionCookie(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        return header.split(separator: ",").lazy
            .map { $0.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
            .first { $0.hasPrefix("connect.sid=") }
    }

    public func currentUser() async throws -> User {
        try await decode(User.self, path: "auth/me")
    }

    // MARK: - 条目与请求

    public func title(_ type: CatalogTitle.MediaType, tmdbID: Int) async throws -> Title {
        struct DTO: Decodable {
            struct MediaInfo: Decodable {
                struct SeasonInfo: Decodable { var seasonNumber: Int?; var status: Int? }
                var status: Int?
                var seasons: [SeasonInfo]?
            }
            struct Season: Decodable { var seasonNumber: Int?; var name: String? }
            var id: Int?
            var title: String?
            var name: String?
            var posterPath: String?
            var mediaInfo: MediaInfo?
            var seasons: [Season]?
        }
        let dto = try await decode(DTO.self, path: "\(type.rawValue)/\(tmdbID)")
        let seasonStatuses = Dictionary(
            (dto.mediaInfo?.seasons ?? []).compactMap { info in info.seasonNumber.map { ($0, info.status ?? 1) } },
            uniquingKeysWith: { first, _ in first }
        )
        return Title(
            tmdbID: dto.id ?? tmdbID,
            mediaType: type,
            name: dto.title ?? dto.name ?? "",
            posterPath: dto.posterPath,
            status: dto.mediaInfo?.status.flatMap(MediaStatus.init(rawValue:)) ?? .unknown,
            seasons: (dto.seasons ?? []).compactMap { season in
                guard let number = season.seasonNumber, number > 0 else { return nil }
                return Title.Season(number: number, name: season.name,
                                    status: seasonStatuses[number].flatMap(MediaStatus.init(rawValue:)) ?? .unknown)
            }
        )
    }

    /// 发起请求；剧集需指定季（nil 时请求全部正片季）。
    public func request(_ type: CatalogTitle.MediaType, tmdbID: Int, seasons: [Int]?) async throws {
        var body: [String: Any] = ["mediaType": type.rawValue, "mediaId": tmdbID, "is4k": false]
        if type == .tv {
            if let seasons {
                body["seasons"] = seasons
            } else {
                body["seasons"] = try await title(.tv, tmdbID: tmdbID).seasons.map(\.number)
            }
        }
        _ = try await send(path: "request", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// 当前用户发起的请求（新的在前）。
    public func myRequests(userID: Int, take: Int = 30) async throws -> [Request] {
        struct DTO: Decodable {
            struct Item: Decodable {
                struct Media: Decodable { var tmdbId: Int?; var mediaType: String?; var status: Int? }
                var id: Int
                var status: Int?
                var media: Media?
                var createdAt: Date?
            }
            var results: [Item]
        }
        let dto = try await decode(DTO.self, path: "request", query: [
            .init(name: "take", value: String(take)), .init(name: "skip", value: "0"),
            .init(name: "filter", value: "all"), .init(name: "sort", value: "added"),
            .init(name: "requestedBy", value: String(userID)),
        ])
        return dto.results.map { item in
            Request(
                id: item.id,
                requestStatus: item.status ?? 0,
                mediaStatus: item.media?.status.flatMap(MediaStatus.init(rawValue:)) ?? .unknown,
                tmdbID: item.media?.tmdbId,
                mediaType: item.media?.mediaType.flatMap(CatalogTitle.MediaType.init(rawValue:)),
                createdAt: item.createdAt
            )
        }
    }

    // MARK: - 请求执行

    private func decode<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path: path, query: query)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            return try Date(text, strategy: .iso8601)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SeerrError.http(200, "响应格式无法识别")
        }
    }

    private func send(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.http(-1, nil) }
        if http.statusCode == 401 || http.statusCode == 403, cookie != nil { throw SeerrError.sessionExpired }
        guard (200..<300).contains(http.statusCode) else { throw SeerrError.http(http.statusCode, Self.message(data)) }
        return data
    }

    /// 错误体中的 `message`。
    static func message(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }
}
