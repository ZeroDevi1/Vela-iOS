import CryptoKit
import Foundation

public enum NavidromeError: LocalizedError, Sendable {
    case invalidAddress
    case invalidResponse
    case incompatibleServer
    case authentication
    case permission
    case unavailable
    case http(Int)
    case service(Int)
    case network(URLError.Code)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入有效的 Navidrome 地址（可包含端口和反代路径）"
        case .invalidResponse: "服务器未返回有效的 Subsonic 响应，请检查地址及反代路径"
        case .incompatibleServer: "此地址不是 Navidrome 服务器"
        case .authentication: "无法验证 Navidrome 账号，请检查凭据或重新登录"
        case .permission: "当前 Navidrome 账号没有此操作权限"
        case .unavailable: "服务器未启用或不支持此功能"
        case .http(let code): "Navidrome 请求失败（HTTP \(code)）"
        case .service(let code): "Navidrome 请求失败（Subsonic \(code)）"
        case .network(let code): URLError(code).localizedDescription
        }
    }
}

public struct NavidromeClient: Sendable {
    public let accountID: String
    public let baseURL: URL
    let username: String
    private let password: String
    private let apiKey: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    public init(accountID: String, baseURL: URL, username: String, password: String, apiKey: String? = nil) {
        self.accountID = accountID
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.apiKey = apiKey
    }

    public static func address(_ input: String) throws -> URL {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = input.contains("://") ? input : "https://" + input
        guard var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw NavidromeError.invalidAddress
        }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw NavidromeError.invalidAddress }
        return url
    }

    public struct Capabilities: Sendable {
        public var extensions: [String: Set<Int>] = [:]
        public func supports(_ name: String, version: Int = 1) -> Bool { extensions[name]?.contains(version) == true }
        public var transcodeOffset: Bool { supports("transcodeOffset") }
        public var playbackReport: Bool { supports("playbackReport") }
    }

    public func ping() async throws {
        let response = try await request("ping")
        if let type = response.type, type.lowercased() != "navidrome" {
            throw NavidromeError.incompatibleServer
        }
    }

    public func capabilities() async -> Capabilities {
        // 老版本可能没有扩展探测端点，仍可使用标准 Subsonic。
        guard let response = try? await request("getOpenSubsonicExtensions", authenticated: false) else { return .init() }
        var versions: [String: Set<Int>] = [:]
        for feature in response.openSubsonicExtensions ?? [] { versions[feature.name, default: []].formUnion(feature.versions) }
        return Capabilities(extensions: versions)
    }

    public func search(_ query: String, limit: Int, songOffset: Int = 0, songsOnly: Bool = false, folder: Int? = nil) async throws -> MusicSearchResults {
        try await request("search3", [
            .init(name: "query", value: query), .init(name: "songCount", value: String(limit)),
            .init(name: "songOffset", value: String(songOffset)), .init(name: "artistCount", value: songsOnly ? "0" : String(limit)),
            .init(name: "albumCount", value: songsOnly ? "0" : String(limit))
        ] + optional("musicFolderId", folder)).searchResult3 ?? MusicSearchResults()
    }

    public func albums(type: String = "alphabeticalByName", limit: Int, offset: Int = 0, folder: Int? = nil) async throws -> [MusicAlbum] {
        try await request("getAlbumList2", [
            .init(name: "type", value: type), .init(name: "size", value: String(limit)), .init(name: "offset", value: String(offset))
        ] + optional("musicFolderId", folder)).albumList2?.album ?? []
    }

    public func album(_ id: String) async throws -> MusicAlbum {
        guard let album = try await request("getAlbum", [Self.id(id)]).album else { throw NavidromeError.invalidResponse }
        return album
    }

    public func artists(folder: Int? = nil) async throws -> [MusicArtist] {
        try await request("getArtists", optional("musicFolderId", folder)).artists?.index?.flatMap { $0.artist ?? [] } ?? []
    }

    public func artist(_ id: String) async throws -> MusicArtist {
        guard let artist = try await request("getArtist", [Self.id(id)]).artist else { throw NavidromeError.invalidResponse }
        return artist
    }

    public func genres(folder: Int? = nil) async throws -> [MusicGenre] {
        try await request("getGenres", optional("musicFolderId", folder)).genres?.genre ?? []
    }

    public func songs(genre: String, limit: Int, offset: Int, folder: Int? = nil) async throws -> [NavidromeTrack] {
        try await request("getSongsByGenre", [
            .init(name: "genre", value: genre), .init(name: "count", value: String(limit)), .init(name: "offset", value: String(offset))
        ] + optional("musicFolderId", folder)).songsByGenre?.song ?? []
    }

    public func favorites() async throws -> MusicSearchResults {
        try await request("getStarred2").starred2 ?? MusicSearchResults()
    }

    public func playlists() async throws -> [MusicPlaylist] {
        try await request("getPlaylists").playlists?.playlist ?? []
    }

    public func playlist(_ id: String) async throws -> MusicPlaylist {
        guard let playlist = try await request("getPlaylist", [Self.id(id)]).playlist else { throw NavidromeError.invalidResponse }
        return playlist
    }

    public func cover(_ id: String, size: Int) async throws -> Data {
        let url = try endpoint("getCoverArt", [Self.id(id), .init(name: "size", value: String(size))])
        return try await artwork(from: url)
    }

    public func artwork(from url: URL) async throws -> Data {
        let (data, response) = try await fetch(url)
        guard response.mimeType?.hasPrefix("image/") == true else { throw NavidromeError.invalidResponse }
        return data
    }

    public func streamURL(id: String, compatible: Bool, offset: Int = 0) throws -> URL {
        var query = [Self.id(id), URLQueryItem(name: "format", value: compatible ? "mp3" : "raw")]
        if compatible {
            query.append(.init(name: "maxBitRate", value: "192"))
            if offset > 0 { query.append(.init(name: "timeOffset", value: String(offset))) }
        }
        return try endpoint("stream", query)
    }

    public enum PlaybackState: String, Sendable { case starting, playing, paused, stopped }

    public func report(id: String, position: TimeInterval, state: PlaybackState, ignoreScrobble: Bool) async throws {
        _ = try await request("reportPlayback", [
            .init(name: "mediaId", value: id), .init(name: "mediaType", value: "song"),
            .init(name: "positionMs", value: String(Int(max(0, position) * 1000))),
            .init(name: "state", value: state.rawValue), .init(name: "ignoreScrobble", value: ignoreScrobble ? "true" : "false")
        ])
    }

    public func scrobble(id: String, submission: Bool) async throws {
        _ = try await request("scrobble", [Self.id(id), .init(name: "submission", value: submission ? "true" : "false")])
    }

    static func id(_ id: String) -> URLQueryItem { .init(name: "id", value: id) }

    func endpoint(_ name: String, _ query: [URLQueryItem], authenticated: Bool = true) throws -> URL {
        var params = query + [
            URLQueryItem(name: "c", value: "Vela"), .init(name: "v", value: "1.16.1"), .init(name: "f", value: "json")
        ]
        if authenticated, let apiKey {
            params.append(.init(name: "apiKey", value: apiKey))
        } else if authenticated {
            let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
            params += [.init(name: "u", value: username), .init(name: "s", value: salt), .init(name: "t", value: token)]
        }
        // URLComponents 允许字面加号；Subsonic 的查询解析会把它当空格。
        let url = try HTTPClient.makeURL(baseURL: baseURL, path: "/rest/\(name).view", query: params)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw NavidromeError.invalidAddress }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = parts.url else { throw NavidromeError.invalidAddress }
        return result
    }

    /// 从串流端点暂存原始 FLAC，沿用串流权限与原始字节。
    public func stageOriginalFLAC(from url: URL) async throws -> URL {
        try await downloadResource(url, fileExtension: "flac").0
    }

    public func checkOriginalFLACRanges(at url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (stream, response) = try await Self.session.bytes(for: request)
        // 这里只检查响应头，服务器忽略 Range 时立即停止读取。
        stream.task.cancel()
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-0/") == true else {
            throw NavidromeError.invalidResponse
        }
    }

    /// 读取原始流的指定范围与完整文件长度。
    public func originalFLACRange(from url: URL, bytes range: Range<Int64>) async throws -> (Data, Int64) {
        guard range.lowerBound >= 0, !range.isEmpty else { throw NavidromeError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let total = Int64(contentRange.split(separator: "/").last ?? ""),
              total > range.lowerBound else {
            throw NavidromeError.invalidResponse
        }
        let end = min(total, range.upperBound)
        let count = Int(end - range.lowerBound)
        guard contentRange == "bytes \(range.lowerBound)-\(end - 1)/\(total)", data.count == count else {
            throw NavidromeError.invalidResponse
        }
        return (data, total)
    }

    func downloadResource(_ url: URL, fileExtension: String? = nil) async throws -> (URL, String?) {
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await Self.session.download(for: URLRequest(url: url, timeoutInterval: 40))
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw NavidromeError.network(error.code)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw NavidromeError.invalidResponse }
        if http.statusCode == 401 { throw NavidromeError.authentication }
        if http.statusCode == 403 { throw NavidromeError.permission }
        guard (200..<300).contains(http.statusCode) else { throw NavidromeError.http(http.statusCode) }
        if let mime = http.mimeType, ["application/json", "application/xml", "text/xml", "text/html"].contains(mime) {
            if let data = try? Data(contentsOf: file),
               let code = try? JSONDecoder().decode(Envelope<Status>.self, from: data).response.error?.code {
                throw code == 50 ? NavidromeError.permission : NavidromeError.service(code)
            }
            throw NavidromeError.invalidResponse
        }
        var stage = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        if let fileExtension { stage.appendPathExtension(fileExtension) }
        try FileManager.default.moveItem(at: file, to: stage)
        return (stage, http.suggestedFilename)
    }

    func fetch(_ url: URL, jsonBody: Data? = nil, form: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        if let jsonBody {
            request.httpMethod = "POST"
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if form, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            request.httpMethod = "POST"
            request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            components.queryItems = nil
            request.url = components.url
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            // 不透传可能带鉴权 URL 的底层错误。
            throw NavidromeError.network(error.code)
        }
        guard let http = response as? HTTPURLResponse else { throw NavidromeError.invalidResponse }
        if http.statusCode == 401 { throw NavidromeError.authentication }
        if http.statusCode == 403 { throw NavidromeError.permission }
        if [410, 501].contains(http.statusCode) { throw NavidromeError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw NavidromeError.http(http.statusCode) }
        return (data, http)
    }

    private func request(_ name: String, _ query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> Response {
        try await subsonic(Response.self, name, query, authenticated: authenticated)
    }

    func subsonic<Value: Decodable>(_ type: Value.Type, _ name: String, _ query: [URLQueryItem] = [],
                                    authenticated: Bool = true, jsonBody: Data? = nil, form: Bool = false) async throws -> Value {
        let (data, _) = try await fetch(endpoint(name, query, authenticated: authenticated), jsonBody: jsonBody, form: form)
        guard let status = try? JSONDecoder().decode(Envelope<Status>.self, from: data).response else {
            throw NavidromeError.invalidResponse
        }
        guard status.status == "ok" else {
            let code = status.error?.code ?? 0
            if (40...44).contains(code) { throw NavidromeError.authentication }
            if code == 50 { throw NavidromeError.permission }
            throw NavidromeError.service(code)
        }
        guard let decoded = try? JSONDecoder().decode(Envelope<Value>.self, from: data).response else {
            throw NavidromeError.invalidResponse
        }
        return decoded
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let from = response.url
            let to = request.url
            let sameOrigin = from?.scheme == to?.scheme && from?.host() == to?.host() && from?.port == to?.port
            completionHandler(sameOrigin ? request : nil)
        }
    }
}

public struct NavidromeTrack: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let artistId: String?
    public let albumId: String?
    public let coverArt: String?
    public let duration: Double?
    public let track: Int?
    public let discNumber: Int?
    public let suffix: String?
    public let contentType: String?
    public let starred: String?
    public let userRating: Int?

    public static func radio(_ station: NavidromeRadio) -> Self {
        .init(id: station.id, title: station.name, artist: "网络电台", album: nil, artistId: nil, albumId: nil,
              coverArt: station.coverArt, duration: nil, track: nil, discNumber: nil, suffix: nil, contentType: nil,
              starred: nil, userRating: nil)
    }
}

public struct MusicAlbum: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let artist: String?
    public let artistId: String?
    public let coverArt: String?
    public let year: Int?
    public let songCount: Int?
    public let duration: Int?
    public let starred: String?
    public let song: [NavidromeTrack]?
}

public struct MusicArtist: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let coverArt: String?
    public let artistImageUrl: String?
    public let albumCount: Int?
    public let starred: String?
    public let album: [MusicAlbum]?
}

public struct MusicGenre: Decodable, Hashable, Identifiable, Sendable {
    public var id: String { value }
    public let value: String
    public let songCount: Int
}

public struct MusicPlaylist: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let coverArt: String?
    public let songCount: Int?
    public let entry: [NavidromeTrack]?
    public let owner: String?
    public let readonly: Bool?
    public let comment: String?
    public let `public`: Bool?
}

public struct MusicSearchResults: Decodable, Sendable {
    public var song: [NavidromeTrack]?
    public var album: [MusicAlbum]?
    public var artist: [MusicArtist]?
}

private struct Envelope<Value: Decodable>: Decodable {
    let response: Value
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

private struct Status: Decodable {
    struct Failure: Decodable { let code: Int }
    let status: String
    let error: Failure?
}

private struct Response: Decodable {
    struct Feature: Decodable { let name: String; let versions: [Int] }
    struct Albums: Decodable { let album: [MusicAlbum]? }
    struct Artists: Decodable {
        struct Index: Decodable { let artist: [MusicArtist]? }
        let index: [Index]?
    }
    struct Genres: Decodable { let genre: [MusicGenre]? }
    struct Songs: Decodable { let song: [NavidromeTrack]? }
    struct Playlists: Decodable { let playlist: [MusicPlaylist]? }
    let type: String?
    let openSubsonicExtensions: [Feature]?
    let searchResult3: MusicSearchResults?
    let starred2: MusicSearchResults?
    let albumList2: Albums?
    let album: MusicAlbum?
    let artists: Artists?
    let artist: MusicArtist?
    let genres: Genres?
    let songsByGenre: Songs?
    let playlists: Playlists?
    let playlist: MusicPlaylist?
}
