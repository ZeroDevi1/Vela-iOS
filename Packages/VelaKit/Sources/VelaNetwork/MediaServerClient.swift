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
    static let listFields = "Overview,Genres,ProviderIds,PrimaryImageAspectRatio,ParentBackdropItemId,ParentBackdropImageTags,CommunityRating,ProductionYear,MediaSourceCount"

    // MARK: - 浏览

    public func userViews() async throws -> [MediaItem] {
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            // ChildCount 用于「我的媒体」卡片下方的「N 项」。
            APIRequest("/Users/\(userID)/Views", query: [.init(name: "Fields", value: "ChildCount,PrimaryImageAspectRatio")]),
            baseURL: baseURL,
            headers: headers
        )
        return result.items.map { $0.toMediaItem(serverID: serverID) }
    }

    public func resumeItems(limit: Int = 20) async throws -> [MediaItem] {
        try await resume(limit: limit).items
    }

    /// 继续观看，附带总数（首页显示「75 ›」）。
    /// - Parameter parentID: 只取某个媒体库内的条目（媒体库「推荐」分段）；nil 为全部。
    public func resume(limit: Int = 20, startIndex: Int = 0, parentID: String? = nil) async throws -> (items: [MediaItem], total: Int) {
        var query: [URLQueryItem] = [
            .init(name: "Limit", value: String(limit)),
            .init(name: "MediaTypes", value: "Video"),
            .init(name: "Fields", value: Self.listFields),
            .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            .init(name: "EnableTotalRecordCount", value: "true")
        ]
        if startIndex > 0 { query.append(.init(name: "StartIndex", value: String(startIndex))) }
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Users/\(userID)/Items/Resume", query: query),
            baseURL: baseURL,
            headers: headers
        )
        let items = result.items.map { $0.toMediaItem(serverID: serverID) }
        return (items, result.totalRecordCount ?? items.count)
    }

    /// 用户头像；用户未设置头像时服务器返回 404，界面显示占位。
    public var userImageURL: URL? {
        try? HTTPClient.makeURL(baseURL: baseURL, path: "/Users/\(userID)/Images/Primary", query: [
            .init(name: "maxWidth", value: "96"),
            .init(name: "quality", value: "90")
        ])
    }

    public func nextUp(limit: Int = 20) async throws -> [MediaItem] {
        try await nextUpPage(limit: limit).items
    }

    /// 接下来播放（各剧的下一集），附带总数。
    /// - Parameter parentID: 只取某个剧集库内的条目；nil 为全部。
    public func nextUpPage(limit: Int = 20, startIndex: Int = 0, parentID: String? = nil) async throws -> (items: [MediaItem], total: Int) {
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: userID),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: Self.listFields),
            .init(name: "EnableTotalRecordCount", value: "true")
        ]
        if startIndex > 0 { query.append(.init(name: "StartIndex", value: String(startIndex))) }
        if let parentID { query.append(.init(name: "ParentId", value: parentID)) }
        query += nextUpCompatibilityQuery
        let result = try await http.decode(
            QueryResult<BaseItemDTO>.self,
            APIRequest("/Shows/NextUp", query: query),
            baseURL: baseURL,
            headers: headers
        )
        let items = result.items.map { $0.toMediaItem(serverID: serverID) }
        return (items, result.totalRecordCount ?? items.count)
    }

    /// NextUp 的公共参数（与 Android 版一致）。Emby 新版的 NextUp 默认算法不返回看了一半的单集，「接下来」常为空；
    /// `LegacyNextUp=true` 恢复旧算法，Jellyfin 不认识该参数，不发送。显式要求图片与用户数据：旧算法下缺省时
    /// 可能不带单集图片 tag 与播放进度，卡片会显示占位图、没有剩余时长。
    var nextUpCompatibilityQuery: [URLQueryItem] {
        var query: [URLQueryItem] = [.init(name: "EnableImages", value: "true"), .init(name: "EnableUserData", value: "true")]
        if kind == .emby { query.append(.init(name: "LegacyNextUp", value: "true")) }
        return query
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
            // 播放前取详情：VR 识别需要 Path / Tags / Video3DFormat，多段文件需要 PartCount。
            APIRequest("/Users/\(userID)/Items/\(id)", query: [
                .init(name: "Fields", value: "Path,Tags,Video3DFormat,PartCount,Chapters,ProviderIds,Overview,MediaSources")
            ]),
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
        capabilities: PlaybackCapabilities,
        profile: DeviceProfile.Kind = .avFoundation
    ) async throws -> PlaybackInfoResponse {
        let body = PlaybackInfoBody(
            userID: userID,
            maxStreamingBitrate: capabilities.maxStreamingBitrate,
            startTimeTicks: startTicks,
            mediaSourceID: mediaSourceID,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            deviceProfile: .make(profile, capabilities)
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

    /// Emby 烧录字幕时直接使用媒体播放列表。其 master 可能把实际 Main / Level 5.1 的 4K H.264
    /// 声明为 High / Level 4.1，导致 AVPlayer 在读取视频分片前报 -12927；main 由分片本身确定解码格式。
    /// 保留原查询中的字幕、转码会话与鉴权参数；不烧录时仍用 master，保留字幕组等信息。
    public func transcodingURL(forServerRelative relative: String, burningSubtitles: Bool) throws -> URL {
        let url = try absoluteURL(forServerRelative: relative)
        guard kind == .emby, burningSubtitles, url.lastPathComponent == "master.m3u8" else { return url }
        return url.deletingLastPathComponent().appendingPathComponent("main.m3u8")
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
    /// 字幕原始格式的地址（带 token），交给 MPV 直接加载；ASS 保留特效。
    /// - Parameter codec: 服务器给出的字幕编码（`ass` / `ssa` / `subrip` / `srt` / `webvtt` …）。
    public func subtitleStreamURL(itemID: String, mediaSourceID: String, streamIndex: Int, codec: String?) throws -> URL {
        let format = switch codec?.lowercased() {
        case "ass": "ass"
        case "ssa": "ssa"
        case "webvtt", "vtt": "vtt"
        default: "srt"
        }
        return try absoluteURL(forServerRelative: "/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/Stream.\(format)")
    }

    /// 文本字幕原文。SRT / WebVTT 直接取原始格式，其余文本格式（ASS 等）请服务器转换为 WebVTT；两者都由 `WebVTTParser` 解析。
    ///
    /// 路径与 Android 版一致（`/Subtitles/{index}/0/Stream.{格式}`，`0` 为起始 tick），SRT 不需要服务器转换格式。
    /// 内嵌字幕要服务器读完整个视频文件才能提取：文件在网盘挂载盘上时可能长达数分钟，超时放宽到 120 秒；
    /// KSPlayer 内核直接从视频流读取内嵌字幕，不走这里。
    public func subtitleText(itemID: String, mediaSourceID: String, streamIndex: Int, codec: String?) async throws -> String {
        let format = switch codec?.lowercased() {
        case "subrip", "srt": "srt"
        default: "vtt"
        }
        let (data, _) = try await http.data(
            APIRequest("/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/0/Stream.\(format)", timeout: 120),
            baseURL: baseURL,
            headers: headers
        )
        guard let text = Self.decodeSubtitleText(data) else {
            throw APIError.decoding("字幕不是文本")
        }
        return text
    }

    /// 字幕文本解码：服务器转换时通常输出 UTF-8，但部分服务器会原样透传字幕文件的编码。
    /// 中文 SRT 常见 GBK / GB18030 或 Big5，按 Latin-1 解码会变成乱码，因此依次尝试，最后才退回 Latin-1。
    public static func decodeSubtitleText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let candidates: [CFStringEncodings] = [.GB_18030_2000, .big5_HKSCS_1999, .big5]
        for candidate in candidates {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(candidate.rawValue)))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
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

    /// 线路探测结果。
    public enum LineProbeResult: Equatable, Sendable {
        /// 可达，附带往返耗时（秒）。
        case reachable(latency: TimeInterval)
        /// 可达但不是同一台服务器（例如局域网地址被分配给了另一台设备）。
        case mismatch
        case unreachable
    }

    /// 探测某条线路：请求 `/System/Info/Public` 并核对服务器实例 id，只有同一台服务器才算可达。
    public static func probeLine(
        _ baseURL: URL,
        expectedServerID: String,
        timeout: TimeInterval = 4,
        http: HTTPClient = HTTPClient()
    ) async -> LineProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, _) = try await http.data(APIRequest("/System/Info/Public", timeout: timeout), baseURL: baseURL, headers: [:])
            let info = try JSONDecoder.server.decode(PublicSystemInfo.self, from: data)
            guard info.id == expectedServerID else { return .mismatch }
            let elapsed = clock.now - start
            return .reachable(latency: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        } catch {
            return .unreachable
        }
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
