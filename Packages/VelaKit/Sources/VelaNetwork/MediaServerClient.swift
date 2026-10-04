import Foundation
import VelaCore

/// Jellyfin / Emby 共用的 API 客户端。值类型、无共享可变状态，可在任意并发上下文使用。
///
/// 一个实例绑定「一台服务器的一条线路 + 一个已登录用户」；线路切换时由会话层重新创建实例。
public struct MediaServerClient: Sendable {
    public let serverID: String
    public let baseURL: URL
    public let kind: MediaServerKind
    public let userID: String
    private let accessToken: String
    private let identity: ClientIdentity
    private let http: HTTPClient

    public init(
        serverID: String,
        baseURL: URL,
        kind: MediaServerKind,
        userID: String,
        accessToken: String,
        identity: ClientIdentity,
        http: HTTPClient = HTTPClient()
    ) {
        self.serverID = serverID
        self.baseURL = baseURL
        self.kind = kind
        self.userID = userID
        self.accessToken = accessToken
        self.identity = identity
        self.http = http
    }

    private var headers: [String: String] {
        AuthorizationHeader(kind: kind, identity: identity, accessToken: accessToken).headers
    }

    /// 供同模块其他文件中的扩展使用。
    var requestHeaders: [String: String] { headers }
    var httpClient: HTTPClient { http }

    /// 列表接口统一请求的附加字段；少请求字段能明显减小响应体。
    static let listFields = "Overview,Genres,ProviderIds,PrimaryImageAspectRatio,ParentBackdropItemId,ParentBackdropImageTags"

    // MARK: - 浏览

    public func userViews() async throws -> [MediaItem] {
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Users/\(userID)/Views"),
            baseURL: baseURL,
            headers: headers
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    public func resumeItems(limit: Int = 20) async throws -> [MediaItem] {
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Users/\(userID)/Items/Resume", query: [
                .init(name: "Limit", value: String(limit)),
                .init(name: "MediaTypes", value: "Video"),
                .init(name: "Fields", value: Self.listFields),
                .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
            ]),
            baseURL: baseURL,
            headers: headers
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    public func nextUp(limit: Int = 20) async throws -> [MediaItem] {
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/NextUp", query: [
                .init(name: "UserId", value: userID),
                .init(name: "Limit", value: String(limit)),
                .init(name: "Fields", value: Self.listFields)
            ]),
            baseURL: baseURL,
            headers: headers
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    /// 最新入库。注意该接口直接返回数组，不是 `QueryResult`。
    public func latestItems(parentID: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        var query: [URLQueryItem] = [
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: Self.listFields)
        ]
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        let items = try await http.decode(
            [BaseItemDTO].self,
            APIRequest("/Users/\(userID)/Items/Latest", query: query),
            baseURL: baseURL,
            headers: headers
        )
        return items.map { $0.toMediaItem(serverID: serverID) }
    }

    public func items(_ query: ItemQuery) async throws -> (items: [MediaItem], total: Int) {
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Users/\(userID)/Items", query: query.queryItems + [.init(name: "Fields", value: Self.listFields)]),
            baseURL: baseURL,
            headers: headers
        )
        let items = result.items.map { $0.toMediaItem(serverID: serverID) }
        return (items, result.totalRecordCount ?? items.count)
    }

    public func item(id: String) async throws -> MediaItem {
        let dto = try await http.decode(
            BaseItemDTO.self,
            APIRequest("/Users/\(userID)/Items/\(id)"),
            baseURL: baseURL,
            headers: headers
        )
        return dto.toMediaItem(serverID: serverID)
    }

    public func search(_ term: String, limit: Int = 50) async throws -> [MediaItem] {
        try await items(ItemQuery(
            searchTerm: term,
            includeItemTypes: ["Movie", "Series", "Episode"],
            recursive: true,
            limit: limit
        )).items
    }

    // MARK: - 播放

    public func playbackInfo(
        itemID: String,
        mediaSourceID: String? = nil,
        startTicks: Int64 = 0,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        capabilities: PlaybackCapabilities
    ) async throws -> PlaybackInfoResponse {
        let body = PlaybackInfoBody(
            userID: userID,
            maxStreamingBitrate: capabilities.maxStreamingBitrate,
            startTimeTicks: startTicks,
            mediaSourceID: mediaSourceID,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            deviceProfile: .avFoundation(capabilities)
        )
        return try await http.decode(
            PlaybackInfoResponse.self,
            try .post("/Items/\(itemID)/PlaybackInfo", json: body, query: [.init(name: "UserId", value: userID)]),
            baseURL: baseURL,
            headers: headers
        )
    }

    /// 直放地址。AVPlayer 无法为每个分片请求注入鉴权头，因此 token 走查询参数。
    public func directStreamURL(itemID: String, mediaSourceID: String, playSessionID: String?, container: String?) throws -> URL {
        var query: [URLQueryItem] = [
            .init(name: "Static", value: "true"),
            .init(name: "MediaSourceId", value: mediaSourceID),
            .init(name: "DeviceId", value: identity.deviceID),
            .init(name: kind.tokenQueryName, value: accessToken)
        ]
        if let playSessionID { query.append(.init(name: "PlaySessionId", value: playSessionID)) }
        let suffix = container.map { "stream.\($0)" } ?? "stream"
        return try HTTPClient.makeURL(baseURL: baseURL, path: "/Videos/\(itemID)/\(suffix)", query: query)
    }

    /// 把服务器返回的相对转码地址补全为绝对地址，并确保携带 token。
    public func absoluteURL(forServerRelative relative: String) throws -> URL {
        guard var components = URLComponents(string: relative) else { throw APIError.invalidURL(relative) }
        var query = components.queryItems ?? []
        if !query.contains(where: { $0.name.caseInsensitiveCompare(kind.tokenQueryName) == .orderedSame || $0.name == "api_key" }) {
            query.append(.init(name: kind.tokenQueryName, value: accessToken))
        }
        components.queryItems = query
        let path = components.path
        return try HTTPClient.makeURL(baseURL: baseURL, path: path, query: components.queryItems ?? [])
    }

    // MARK: - 播放上报

    public enum ReportEvent: Sendable {
        case start
        /// `timeupdate` / `pause` / `unpause`。
        case progress(eventName: String)
        case stopped
    }

    /// 播放状态上报。服务器据此更新继续观看进度、已看标记与管理面板中的会话。
    public func reportPlayback(_ event: ReportEvent, state: PlaybackReportState) async throws {
        let path: String
        var eventName: String?
        switch event {
        case .start: path = "/Sessions/Playing"
        case .progress(let name): path = "/Sessions/Playing/Progress"; eventName = name
        case .stopped: path = "/Sessions/Playing/Stopped"
        }
        let body = PlaybackReportBody(
            itemID: state.itemID,
            mediaSourceID: state.mediaSourceID,
            playSessionID: state.playSessionID,
            positionTicks: Ticks.ticks(state.position),
            isPaused: state.isPaused,
            playMethod: state.playMethod,
            audioStreamIndex: state.audioStreamIndex,
            subtitleStreamIndex: state.subtitleStreamIndex,
            eventName: eventName
        )
        _ = try await http.data(try .post(path, json: body), baseURL: baseURL, headers: headers)
    }

    /// 结束本设备在服务器上的转码进程。不调用时服务器会继续转码直到超时，白白占用 CPU / GPU。
    public func stopActiveEncodings(playSessionID: String) async throws {
        _ = try await http.data(
            APIRequest("/Videos/ActiveEncodings", method: .delete, query: [
                .init(name: "DeviceId", value: identity.deviceID),
                .init(name: "PlaySessionId", value: playSessionID)
            ]),
            baseURL: baseURL,
            headers: headers
        )
    }

    // MARK: - 片段 / 字幕 / 剧集

    /// Jellyfin 10.10+ 的片头 / 片尾片段。Emby 及旧版 Jellyfin 没有该接口（404），调用方应回退到章节标记。
    public func mediaSegments(itemID: String) async throws -> [PlaybackSegment] {
        let result = try await http.decode(
            QueryResult<MediaSegmentDTO>.self,
            APIRequest("/MediaSegments/\(itemID)", query: [
                .init(name: "includeSegmentTypes", value: "Intro"),
                .init(name: "includeSegmentTypes", value: "Outro"),
                .init(name: "includeSegmentTypes", value: "Recap"),
                .init(name: "includeSegmentTypes", value: "Preview")
            ]),
            baseURL: baseURL,
            headers: headers
        )
        return result.items.compactMap { dto in
            let kind: PlaybackSegment.Kind
            switch dto.type {
            case "Intro": kind = .intro
            case "Outro": kind = .outro
            case "Recap": kind = .recap
            case "Preview": kind = .preview
            default: return nil
            }
            return PlaybackSegment(kind: kind, start: Ticks.seconds(dto.startTicks), end: Ticks.seconds(dto.endTicks))
        }
    }

    /// 把任意文本字幕（内嵌 / 外挂、SRT / ASS 等）交给服务器转换为 WebVTT 后下载。
    public func subtitleWebVTT(itemID: String, mediaSourceID: String, streamIndex: Int) async throws -> String {
        let (data, _) = try await http.data(
            APIRequest("/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/Stream.vtt", timeout: 30),
            baseURL: baseURL,
            headers: headers
        )
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw APIError.decoding("字幕不是文本")
        }
        return text
    }

    /// 剧集的全部单集（按播出顺序）。用于确定「下一集」；只请求必要字段以减小长篇番剧的响应体。
    public func episodes(seriesID: String) async throws -> [MediaItem] {
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/\(seriesID)/Episodes", query: [
                .init(name: "UserId", value: userID),
                .init(name: "Fields", value: "Overview,ParentBackdropItemId,ParentBackdropImageTags")
            ]),
            baseURL: baseURL,
            headers: headers
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    // MARK: - 图片

    /// 图片地址带 tag，内容变化时 URL 随之变化，因此可以长期缓存。没有对应 tag 时返回 nil，避免请求必然 404 的地址。
    public func imageURL(for item: MediaItem, kind imageKind: MediaItem.ImageKind, maxWidth: Int) -> URL? {
        let target: (id: String, tag: String)?
        switch imageKind {
        case .backdrop:
            if let tag = item.backdropImageTags.first {
                target = (item.id, tag)
            } else if let parent = item.parentBackdropItemID, let tag = item.parentBackdropImageTags.first {
                target = (parent, tag)
            } else {
                target = nil
            }
        default:
            target = item.imageTags[imageKind].map { (item.id, $0) }
        }
        guard let target else { return nil }
        return try? HTTPClient.makeURL(
            baseURL: baseURL,
            path: "/Items/\(target.id)/Images/\(imageKind.rawValue)",
            query: [
                .init(name: "tag", value: target.tag),
                .init(name: "maxWidth", value: String(maxWidth)),
                .init(name: "quality", value: "90")
            ]
        )
    }
}

// MARK: - 匿名接口（登录前）

public enum MediaServerProbe {
    public struct Result: Sendable {
        public var baseURL: URL
        public var info: PublicSystemInfo
        public var kind: MediaServerKind
    }

    /// 依次尝试候选地址，返回第一个能识别为 Jellyfin / Emby 的服务器。
    public static func probe(_ input: String, http: HTTPClient = HTTPClient()) async throws -> Result {
        let candidates = ServerDiscovery.candidates(for: input)
        guard !candidates.isEmpty else { throw APIError.invalidURL(input) }
        var lastError: any Error = APIError.invalidURL(input)
        for url in candidates {
            do {
                let (data, response) = try await http.data(
                    APIRequest("/System/Info/Public", timeout: 8),
                    baseURL: url,
                    headers: [:]
                )
                let info = try JSONDecoder.server.decode(PublicSystemInfo.self, from: data)
                guard info.id != nil else { continue }
                let kind = ServerDiscovery.detectKind(
                    info: info,
                    applicationHeader: response.value(forHTTPHeaderField: "X-Application")
                ) ?? .jellyfin
                return Result(baseURL: url, info: info, kind: kind)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func authenticate(
        baseURL: URL,
        kind: MediaServerKind,
        username: String,
        password: String,
        identity: ClientIdentity,
        http: HTTPClient = HTTPClient()
    ) async throws -> AuthenticationResult {
        do {
            return try await http.decode(
                AuthenticationResult.self,
                try .post("/Users/AuthenticateByName", json: AuthenticateByNameBody(username: username, password: password)),
                baseURL: baseURL,
                headers: AuthorizationHeader(kind: kind, identity: identity).headers
            )
        } catch APIError.unauthorized {
            throw APIError.invalidCredentials
        }
    }
}
