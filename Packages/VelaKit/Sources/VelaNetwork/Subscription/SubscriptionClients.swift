import Foundation
import VelaCore

/// MoviePilot v2 接口（`/api/v1`）。订阅真相源在 MoviePilot，客户端只读写、不缓存。
public struct MoviePilotClient: Sendable {
    public enum MoviePilotError: LocalizedError {
        case invalidURL
        case loginRequired
        /// 账号开启了二次验证，登录时必须填写验证码（后端返回 401 +「需要二次验证」）。
        case mfaRequired
        /// 非 2xx；`detail` 为后端 FastAPI 错误体中的 `detail`（可能为空）。
        case http(Int, detail: String?)
        case rejected(String)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "MoviePilot 地址无效"
            case .loginRequired: "MoviePilot 登录已失效，请重新连接"
            case .mfaRequired: "该账号已开启二次验证，请填写两步验证码后再连接"
            case .http(let status, let detail):
                detail.map { "MoviePilot 返回错误（HTTP \(status)）：\($0)" } ?? "MoviePilot 返回错误（HTTP \(status)）"
            case .rejected(let message): message
            case .malformed: "无法解析 MoviePilot 响应"
            }
        }
    }

    /// 某季的一集（来自 MoviePilot 代理的 TMDB 数据）。
    public struct Episode: Sendable {
        public var number: Int?
        public var name: String?
        public var airDate: String?
    }

    public let baseURL: URL
    private let token: String?
    private let session: URLSession

    /// - Parameter baseURL: 用户输入的地址，可带或不带 `/api/v1`。
    public init(baseURL: String, token: String? = nil, session: URLSession = .shared) throws {
        guard let url = Self.normalize(baseURL) else { throw MoviePilotError.invalidURL }
        self.baseURL = url
        self.token = token
        self.session = session
    }

    /// 去掉末尾斜杠与 `/api/v1`；只接受不带账号、查询与片段的 http(s) 地址。
    public static func normalize(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/api/v1") { value.removeLast("/api/v1".count) }
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil, components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }

    private var apiRoot: URL { baseURL.appending(path: "api/v1") }

    // MARK: - 接口

    /// 用户名密码换 access token（表单提交）。
    public func login(username: String, password: String, otp: String = "") async throws -> String {
        var request = URLRequest(url: apiRoot.appending(path: "login/access-token"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "username", value: username), .init(name: "password", value: password)]
        if !otp.isEmpty { form.queryItems?.append(.init(name: "otp_password", value: otp)) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let object = try await send(request, authorized: false)
        guard let token = (object as? [String: Any]).flatMap({ JSONValue.string($0["access_token"]) }) else {
            throw MoviePilotError.malformed
        }
        return token
    }

    public func subscriptions() async throws -> [SubscriptionRecord] {
        guard let rows = try await get("subscribe/") as? [[String: Any]] else { throw MoviePilotError.malformed }
        return rows.compactMap(Self.parseSubscription)
    }

    public func addSubscription(_ title: CatalogTitle, season: Int?) async throws {
        var body: [String: Any] = [
            "name": title.title,
            "tmdbid": title.tmdbID,
            "type": title.mediaType == .movie ? "电影" : "电视剧"
        ]
        if let year = title.year { body["year"] = String(year) }
        if let season { body["season"] = season }
        var request = URLRequest(url: apiRoot.appending(path: "subscribe/"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Self.checkSuccess(try await send(request, authorized: true))
    }

    public func removeSubscription(id: Int) async throws {
        var request = URLRequest(url: apiRoot.appending(path: "subscribe/\(id)"), timeoutInterval: 15)
        request.httpMethod = "DELETE"
        try Self.checkSuccess(try await send(request, authorized: true))
    }

    /// 某季各集的播出日期。
    public func episodes(tmdbID: Int, season: Int, episodeGroup: String? = nil) async throws -> [Episode] {
        var query: [String: String] = [:]
        if let episodeGroup { query["episode_group"] = episodeGroup }
        guard let rows = try await get("tmdb/\(tmdbID)/\(season)", query) as? [[String: Any]] else { throw MoviePilotError.malformed }
        return rows.map { Episode(number: JSONValue.int($0["episode_number"]), name: JSONValue.string($0["name"]), airDate: JSONValue.string($0["air_date"])) }
    }

    /// 电影上映日期。
    public func movieReleaseDate(tmdbID: Int) async throws -> String? {
        let object = try await get("media/tmdb:\(tmdbID)", ["type_name": "电影"]) as? [String: Any]
        return object.flatMap { JSONValue.string($0["release_date"]) }
    }

    /// 豆瓣搜索（经 MoviePilot 代理）。
    public func searchDouban(_ query: String) async throws -> [DoubanTitle] {
        guard let rows = try await get("media/search", ["title": query, "source": "douban", "count": "30"]) as? [[String: Any]] else {
            throw MoviePilotError.malformed
        }
        return rows.compactMap { row in
            guard let id = JSONValue.string(row["douban_id"]), let title = JSONValue.string(row["title"]) else { return nil }
            return DoubanTitle(
                doubanID: id,
                title: title,
                overview: JSONValue.string(row["overview"]),
                posterURL: JSONValue.string(row["poster_path"]).flatMap(URL.init(string:)),
                mediaType: JSONValue.string(row["type"]) == "电影" ? .movie : .tv,
                year: JSONValue.string(row["year"]) ?? JSONValue.string(row["release_date"]).map { String($0.prefix(4)) },
                tmdbID: JSONValue.int(row["tmdb_id"]).flatMap { $0 > 0 ? $0 : nil },
                imdbID: JSONValue.string(row["imdb_id"]),
                rating: JSONValue.double(row["vote_average"])
            )
        }
    }

    // MARK: - 解析

    static func parseSubscription(_ row: [String: Any]) -> SubscriptionRecord? {
        guard let id = JSONValue.int(row["id"]), id > 0 else { return nil }
        let type = SubscriptionRecord.mediaType(fromMoviePilot: JSONValue.string(row["type"]))
        return SubscriptionRecord(
            id: id,
            name: JSONValue.string(row["name"]) ?? "",
            posterURL: JSONValue.string(row["poster"]).flatMap(URL.init(string:)),
            mediaType: type,
            season: type == .tv ? JSONValue.int(row["season"]).flatMap { $0 >= 0 ? $0 : nil } : nil,
            tmdbID: JSONValue.int(row["tmdbid"]).flatMap { $0 > 0 ? $0 : nil },
            year: JSONValue.string(row["year"]),
            state: JSONValue.string(row["state"]),
            totalEpisodes: JSONValue.int(row["total_episode"]).flatMap { $0 > 0 ? $0 : nil },
            lackEpisodes: JSONValue.int(row["lack_episode"]),
            episodeGroup: JSONValue.string(row["episode_group"])
        )
    }

    private static func checkSuccess(_ object: Any) throws {
        guard let result = object as? [String: Any] else { throw MoviePilotError.malformed }
        if JSONValue.bool(result["success"]) != true {
            throw MoviePilotError.rejected(JSONValue.string(result["message"]) ?? "MoviePilot 拒绝了此操作")
        }
    }

    /// FastAPI 错误体的 `detail`：字符串，或校验错误的 `[{"msg": …}]` 列表；取不到时为 nil。
    static func errorDetail(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = JSONValue.string(object["detail"]) { return text }
        if let items = object["detail"] as? [[String: Any]] {
            let messages = items.compactMap { JSONValue.string($0["msg"]) }
            return messages.isEmpty ? nil : messages.joined(separator: "；")
        }
        return JSONValue.string(object["message"])
    }

    // MARK: - 请求

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Any {
        var components = URLComponents(url: apiRoot.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // `appending(path:)` 会去掉末尾斜杠，MoviePilot 的列表接口需要保留。
        if path.hasSuffix("/"), !components.path.hasSuffix("/") { components.path += "/" }
        return try await send(URLRequest(url: components.url!, timeoutInterval: 15), authorized: true)
    }

    private func send(_ request: URLRequest, authorized: Bool) async throws -> Any {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            guard let token else { throw MoviePilotError.loginRequired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoviePilotError.http(-1, detail: nil) }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403:
            if authorized { throw MoviePilotError.loginRequired }
            // 登录接口：密码正确但需要二次验证时同样是 401，靠响应头 / detail 区分，不能一律报「密码错误」。
            let detail = Self.errorDetail(data)
            if http.value(forHTTPHeaderField: "X-MFA-Required") == "true" || detail == "需要二次验证" {
                throw MoviePilotError.mfaRequired
            }
            throw MoviePilotError.rejected(detail ?? "用户名或密码错误")
        default:
            throw MoviePilotError.http(http.statusCode, detail: Self.errorDetail(data))
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw MoviePilotError.malformed
        }
    }
}

/// 豆瓣条目（经 MoviePilot 搜索）。只有带 TMDB / IMDb id 的结果才能进入目录详情。
public struct DoubanTitle: Identifiable, Hashable, Sendable {
    public var id: String { doubanID }
    public var doubanID: String
    public var title: String
    public var overview: String?
    public var posterURL: URL?
    public var mediaType: CatalogTitle.MediaType
    public var year: String?
    public var tmdbID: Int?
    public var imdbID: String?
    public var rating: Double?
}

/// Bangumi 公开放送日历（`api.bgm.tv/calendar`），无需登录。
public struct BangumiClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public struct Subject: Sendable {
        public var id: Int
        public var name: String
        public var nameCN: String?
        public var imageURL: URL?
        /// 1 = 周一 … 7 = 周日。
        public var weekday: Int
    }

    public func calendar() async throws -> [Subject] {
        var request = URLRequest(url: URL(string: "https://api.bgm.tv/calendar")!, timeoutInterval: 15)
        // Bangumi 要求带可识别的 User-Agent。
        request.setValue("VelaCalendar/1.0 (https://github.com/ZeroDevi1/Vela)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MoviePilotClient.MoviePilotError.http((response as? HTTPURLResponse)?.statusCode ?? -1, detail: nil)
        }
        guard let days = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MoviePilotClient.MoviePilotError.malformed
        }
        return days.flatMap { day -> [Subject] in
            guard let weekday = JSONValue.int((day["weekday"] as? [String: Any])?["id"]),
                  let items = day["items"] as? [[String: Any]] else { return [] }
            return items.compactMap { item in
                guard let id = JSONValue.int(item["id"]) else { return nil }
                let images = item["images"] as? [String: Any]
                let image = JSONValue.string(images?["large"]) ?? JSONValue.string(images?["common"])
                return Subject(
                    id: id,
                    name: JSONValue.string(item["name"]) ?? "",
                    nameCN: JSONValue.string(item["name_cn"]),
                    imageURL: image.flatMap { URL(string: $0.replacingOccurrences(of: "http://", with: "https://")) },
                    weekday: weekday
                )
            }
        }
    }
}

/// `JSONSerialization` 结果的宽松读取：MoviePilot 的同一字段可能是数字或字符串。
enum JSONValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.isEmpty ? nil : text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["true", "1"].contains(text.lowercased())
        default: nil
        }
    }
}
