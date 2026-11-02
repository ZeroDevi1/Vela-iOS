import Foundation

// Jellyfin / Emby 共用的 PascalCase DTO。只声明当前用到的字段，新增字段时按需补充。

public struct PublicSystemInfo: Decodable, Sendable {
    public var serverName: String?
    public var productName: String?
    public var version: String?
    public var id: String?
    public var localAddress: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case productName = "ProductName"
        case version = "Version"
        case id = "Id"
        case localAddress = "LocalAddress"
    }
}

struct AuthenticateByNameBody: Encodable, Sendable {
    let username: String
    let password: String

    /// 只发送明文字段 `Pw`。Emby 的 `Password` 是旧版 SHA1 哈希字段，
    /// 若同时携带明文 `Password`，Emby 会按哈希校验并返回 401（多次失败还可能触发账号锁定）。
    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

public struct AuthenticationResult: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public var id: String
        public var name: String
        public var serverID: String?
        public var primaryImageTag: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case serverID = "ServerId"
            case primaryImageTag = "PrimaryImageTag"
        }
    }

    public var user: User
    public var accessToken: String
    public var serverID: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverID = "ServerId"
    }
}

public struct QueryResult<Item: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Item]
    public var totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct BaseItemDTO: Decodable, Sendable {
    struct UserData: Decodable, Sendable {
        var playbackPositionTicks: Int64?
        var played: Bool?
        var isFavorite: Bool?
        var unplayedItemCount: Int?
        var lastPlayedDate: Date?

        enum CodingKeys: String, CodingKey {
            case lastPlayedDate = "LastPlayedDate"
            case playbackPositionTicks = "PlaybackPositionTicks"
            case played = "Played"
            case isFavorite = "IsFavorite"
            case unplayedItemCount = "UnplayedItemCount"
        }
    }

    var id: String
    var name: String?
    var type: String?
    var overview: String?
    var productionYear: Int?
    var seriesID: String?
    var seriesName: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var runTimeTicks: Int64?
    var communityRating: Double?
    var officialRating: String?
    var genres: [String]?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var screenshotImageTags: [String]?
    var parentBackdropItemID: String?
    var parentBackdropImageTags: [String]?
    var providerIDs: [String: String]?
    var userData: UserData?
    var chapters: [ChapterDTO]?
    var parentLogoItemID: String?
    var parentLogoImageTag: String?
    var seasonID: String?
    var premiereDate: Date?
    var childCount: Int?
    var dateCreated: Date?
    var path: String?
    var taglines: [String]?
    var people: [PersonDTO]?
    var studios: [NameIDDTO]?
    /// 带 id 的类型（Fields 含 Genres 时返回），详情页类型胶囊据此跳转类型条目列表。
    var genreItems: [NameIDDTO]?
    var mediaSources: [MediaSourceInfo]?
    var status: String?
    var endDate: Date?
    var remoteTrailers: [RemoteTrailerDTO]?
    var collectionType: String?
    var productionLocations: [String]?
    var mediaSourceCount: Int?
    var tags: [String]?
    var video3DFormat: String?
    var partCount: Int?
    var localTrailerCount: Int?

    struct RemoteTrailerDTO: Decodable, Sendable {
        var url: String
        var name: String?

        enum CodingKeys: String, CodingKey { case url = "Url", name = "Name" }
    }

    struct ChapterDTO: Decodable, Sendable {
        var name: String?
        var startPositionTicks: Int64
        var markerType: String?
        var imageTag: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case startPositionTicks = "StartPositionTicks"
            case markerType = "MarkerType"
            case imageTag = "ImageTag"
        }
    }

    struct PersonDTO: Decodable, Sendable {
        var id: String
        var name: String
        var role: String?
        var type: String?
        var primaryImageTag: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", role = "Role", type = "Type", primaryImageTag = "PrimaryImageTag"
        }
    }

    struct NameIDDTO: Decodable, Sendable {
        var name: String
        var id: String?

        enum CodingKeys: String, CodingKey { case name = "Name", id = "Id" }

        /// Emby 的 Studios / GenreItems 的 Id 是数字，Jellyfin 是字符串，两种都接受。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let text = try? c.decodeIfPresent(String.self, forKey: .id) {
                id = text
            } else if let number = try? c.decodeIfPresent(Int64.self, forKey: .id) {
                id = String(number)
            } else {
                id = nil
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case seriesID = "SeriesId"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case genres = "Genres"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case screenshotImageTags = "ScreenshotImageTags"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case providerIDs = "ProviderIds"
        case userData = "UserData"
        case chapters = "Chapters"
        case parentLogoItemID = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case seasonID = "SeasonId"
        case premiereDate = "PremiereDate"
        case childCount = "ChildCount"
        case dateCreated = "DateCreated"
        case path = "Path"
        case taglines = "Taglines"
        case people = "People"
        case studios = "Studios"
        case genreItems = "GenreItems"
        case mediaSources = "MediaSources"
        case status = "Status"
        case endDate = "EndDate"
        case remoteTrailers = "RemoteTrailers"
        case localTrailerCount = "LocalTrailerCount"
        case collectionType = "CollectionType"
        case productionLocations = "ProductionLocations"
        case mediaSourceCount = "MediaSourceCount"
        case tags = "Tags"
        case video3DFormat = "Video3DFormat"
        case partCount = "PartCount"
    }
}

/// Jellyfin 10.10+ `/MediaSegments/{itemId}`。
struct MediaSegmentDTO: Decodable, Sendable {
    var type: String
    var startTicks: Int64
    var endTicks: Int64

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }
}

/// `/Sessions/Playing*` 的请求体。
struct PlaybackReportBody: Encodable, Sendable {
    var itemID: String
    var mediaSourceID: String
    var playSessionID: String?
    var positionTicks: Int64
    var isPaused: Bool
    var playMethod: String
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    /// 进度事件名：`timeupdate` / `pause` / `unpause`；Start / Stopped 时为 nil。
    var eventName: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case eventName = "EventName"
        case canSeek = "CanSeek"
        case isMuted = "IsMuted"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(itemID, forKey: .itemID)
        try c.encode(mediaSourceID, forKey: .mediaSourceID)
        try c.encodeIfPresent(playSessionID, forKey: .playSessionID)
        try c.encode(positionTicks, forKey: .positionTicks)
        try c.encode(isPaused, forKey: .isPaused)
        try c.encode(playMethod, forKey: .playMethod)
        try c.encodeIfPresent(audioStreamIndex, forKey: .audioStreamIndex)
        try c.encodeIfPresent(subtitleStreamIndex, forKey: .subtitleStreamIndex)
        try c.encodeIfPresent(eventName, forKey: .eventName)
        try c.encode(true, forKey: .canSeek)
        try c.encode(false, forKey: .isMuted)
    }
}
