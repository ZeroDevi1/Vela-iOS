import Foundation

/// 与后端无关的媒体条目。网络层把 Jellyfin / Emby 的 `BaseItemDto` 映射到这里，界面只依赖此模型。
public struct MediaItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case movie, series, season, episode, video, musicVideo
        case collectionFolder, folder, boxSet, playlist
        case person, audio, other

        /// 可直接进入播放流程的条目类型。
        public var isPlayable: Bool {
            switch self {
            case .movie, .episode, .video, .musicVideo: true
            default: false
            }
        }
    }

    public enum ImageKind: String, Sendable {
        case primary = "Primary"
        case backdrop = "Backdrop"
        case thumb = "Thumb"
        case logo = "Logo"
    }

    /// 服务器内条目 id；跨服务器唯一性由 `serverID` 保证。
    public let id: String
    /// 所属 `SavedServer.id`。
    public let serverID: String
    public var name: String
    public var kind: Kind
    public var overview: String?
    public var productionYear: Int?
    public var seriesID: String?
    public var seriesName: String?
    /// 剧集集号 / 季号。
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    /// 总时长，单位为 Jellyfin tick（100 ns）。
    public var runTimeTicks: Int64?
    /// 已播放位置，单位为 tick。
    public var playbackPositionTicks: Int64?
    public var isPlayed: Bool
    public var isFavorite: Bool
    public var communityRating: Double?
    public var officialRating: String?
    public var genres: [String]
    /// 图片类型 → 服务器图片 tag，用于构造可缓存的图片 URL。
    public var imageTags: [ImageKind: String]
    public var backdropImageTags: [String]
    /// 剧集没有自己的背景图时，回退到父级（剧）的图片。
    public var parentBackdropItemID: String?
    public var parentBackdropImageTags: [String]
    /// TMDB / IMDb 等外部 id，跨服务器匹配同一作品时使用；不能用标题模糊匹配替代。
    public var providerIDs: [String: String]
    /// 章节（含 Emby 片头 / 片尾标记）；列表接口不返回，只有单条目详情才有。
    public var chapters: [MediaChapter]
    /// 剧集 / 季没有自己的 Logo 时，回退到所属剧的 Logo。
    public var parentLogoItemID: String?
    public var parentLogoImageTag: String?
    public var seasonID: String?
    public var premiereDate: Date?
    /// 剧：季数；季：集数（服务器提供时）。
    public var childCount: Int?
    /// 剧 / 季内未看集数。
    public var unplayedItemCount: Int?

    public init(
        id: String,
        serverID: String,
        name: String,
        kind: Kind,
        overview: String? = nil,
        productionYear: Int? = nil,
        seriesID: String? = nil,
        seriesName: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        runTimeTicks: Int64? = nil,
        playbackPositionTicks: Int64? = nil,
        isPlayed: Bool = false,
        isFavorite: Bool = false,
        communityRating: Double? = nil,
        officialRating: String? = nil,
        genres: [String] = [],
        imageTags: [ImageKind: String] = [:],
        backdropImageTags: [String] = [],
        parentBackdropItemID: String? = nil,
        parentBackdropImageTags: [String] = [],
        providerIDs: [String: String] = [:],
        chapters: [MediaChapter] = [],
        parentLogoItemID: String? = nil,
        parentLogoImageTag: String? = nil,
        seasonID: String? = nil,
        premiereDate: Date? = nil,
        childCount: Int? = nil,
        unplayedItemCount: Int? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.kind = kind
        self.overview = overview
        self.productionYear = productionYear
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.runTimeTicks = runTimeTicks
        self.playbackPositionTicks = playbackPositionTicks
        self.isPlayed = isPlayed
        self.isFavorite = isFavorite
        self.communityRating = communityRating
        self.officialRating = officialRating
        self.genres = genres
        self.imageTags = imageTags
        self.backdropImageTags = backdropImageTags
        self.parentBackdropItemID = parentBackdropItemID
        self.parentBackdropImageTags = parentBackdropImageTags
        self.providerIDs = providerIDs
        self.chapters = chapters
        self.parentLogoItemID = parentLogoItemID
        self.parentLogoImageTag = parentLogoImageTag
        self.seasonID = seasonID
        self.premiereDate = premiereDate
        self.childCount = childCount
        self.unplayedItemCount = unplayedItemCount
    }

    /// 已播放比例 0...1；缺少时长或进度时为 nil，界面据此决定是否显示进度条。
    public var playedFraction: Double? {
        guard let total = runTimeTicks, total > 0, let position = playbackPositionTicks, position > 0 else {
            return nil
        }
        return min(1, Double(position) / Double(total))
    }

    /// 剧集显示为 `S01E02`，其余为 nil。
    public var episodeLabel: String? {
        guard kind == .episode, let episode = indexNumber else { return nil }
        let season = parentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
        return season + String(format: "E%02d", episode)
    }
}

public enum Ticks {
    /// Jellyfin / Emby 时间单位：1 tick = 100 ns。
    public static let perSecond: Int64 = 10_000_000

    public static func seconds(_ ticks: Int64) -> TimeInterval {
        TimeInterval(ticks) / TimeInterval(perSecond)
    }

    public static func ticks(_ seconds: TimeInterval) -> Int64 {
        Int64(seconds * TimeInterval(perSecond))
    }
}
