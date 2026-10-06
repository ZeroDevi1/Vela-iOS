import Foundation
import Observation
import VelaCore

/// 「媒体库配置」：首页、继续观看、列表、海报与详情页的显示偏好，持久化在 UserDefaults，修改即时生效。
@MainActor
@Observable
public final class LibraryPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: 首页
    public var showMyMedia: Bool { didSet { save(showMyMedia, "library.showMyMedia") } }
    public var showHero: Bool { didSet { save(showHero, "library.showHero") } }
    /// 首页「最近添加」等分区隐藏已看完的条目（继续观看不受影响）。
    public var hideWatched: Bool { didSet { save(hideWatched, "library.hideWatched") } }

    // MARK: 继续观看
    public var showResume: Bool { didSet { save(showResume, "library.showResume") } }
    public var showNextUp: Bool { didSet { save(showNextUp, "library.showNextUp") } }
    /// 继续观看 / 接下来的卡片用单集截图；关闭时用剧集背景图。
    public var useEpisodeImages: Bool { didSet { save(useEpisodeImages, "library.useEpisodeImages") } }
    /// 继续观看卡片上显示播放按钮，点击直接续播（不进入详情页）。
    public var showPlayButton: Bool { didSet { save(showPlayButton, "library.showPlayButton") } }

    // MARK: 列表
    /// 媒体库列表中把属于合集的电影折叠为合集条目。
    public var showCollections: Bool { didSet { save(showCollections, "library.showCollections") } }
    /// 混合内容（未指定类型）媒体库默认打开的视图。
    public var mixedContentView: MixedContentView { didSet { save(mixedContentView.rawValue, "library.mixedContentView") } }
    public var preferredVersion: MediaVersionPreference { didSet { save(preferredVersion.rawValue, "library.preferredVersion") } }
    public var heroStyle: ArtworkStyle { didSet { save(heroStyle.rawValue, "library.heroStyle") } }
    /// 首页轮播高度（Android「旋转木马高度」）。
    public var heroSize: HeroSize { didSet { save(heroSize.rawValue, "library.heroSize") } }
    public var detailHeaderStyle: ArtworkStyle { didSet { save(detailHeaderStyle.rawValue, "library.detailHeaderStyle") } }

    // MARK: 海报
    public var titleAlignment: TitleAlignment { didSet { save(titleAlignment.rawValue, "library.titleAlignment") } }
    public var showRating: Bool { didSet { save(showRating, "library.showRating") } }
    public var showPlayedMark: Bool { didSet { save(showPlayedMark, "library.showPlayedMark") } }
    public var showUnplayedCount: Bool { didSet { save(showUnplayedCount, "library.showUnplayedCount") } }

    // MARK: 详情页
    public var showCast: Bool { didSet { save(showCast, "library.detail.showCast") } }
    /// 剧集详情的季 / 集选择器。
    public var showEpisodeIndicator: Bool { didSet { save(showEpisodeIndicator, "library.detail.showEpisodeIndicator") } }
    public var showMediaInfo: Bool { didSet { save(showMediaInfo, "library.detail.showMediaInfo") } }
    public var showDoubanLink: Bool { didSet { save(showDoubanLink, "library.detail.showDoubanLink") } }
    public var showSimilar: Bool { didSet { save(showSimilar, "library.detail.showSimilar") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        func raw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        showMyMedia = value("library.showMyMedia", true)
        showHero = value("library.showHero", true)
        hideWatched = value("library.hideWatched", false)
        showResume = value("library.showResume", true)
        showNextUp = value("library.showNextUp", true)
        useEpisodeImages = value("library.useEpisodeImages", true)
        showPlayButton = value("library.showPlayButton", false)
        showCollections = value("library.showCollections", false)
        mixedContentView = raw("library.mixedContentView", .folders)
        preferredVersion = MediaVersionPreference.stored(defaults.string(forKey: "library.preferredVersion")) ?? .serverDefault
        heroStyle = raw("library.heroStyle", .poster)
        heroSize = raw("library.heroSize", .large)
        detailHeaderStyle = raw("library.detailHeaderStyle", .backdrop)
        titleAlignment = raw("library.titleAlignment", .leading)
        showRating = value("library.showRating", true)
        showPlayedMark = value("library.showPlayedMark", true)
        showUnplayedCount = value("library.showUnplayedCount", true)
        showCast = value("library.detail.showCast", true)
        showEpisodeIndicator = value("library.detail.showEpisodeIndicator", true)
        showMediaInfo = value("library.detail.showMediaInfo", true)
        showDoubanLink = value("library.detail.showDoubanLink", true)
        showSimilar = value("library.detail.showSimilar", true)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    public enum MixedContentView: String, CaseIterable, Sendable {
        case folders, all

        public var title: String {
            switch self {
            case .folders: "文件夹"
            case .all: "全部"
            }
        }
    }

    public enum ArtworkStyle: String, CaseIterable, Sendable {
        case poster, backdrop

        public var title: String {
            switch self {
            case .poster: "海报 (竖版)"
            case .backdrop: "背景图 (横版)"
            }
        }
    }

    public enum HeroSize: String, CaseIterable, Sendable {
        case large, medium, small

        public var title: String {
            switch self {
            case .large: "大号"
            case .medium: "中等"
            case .small: "小"
            }
        }

        /// 相对「大号」（此前的固定高度）的比例。
        public var scale: CGFloat {
            switch self {
            case .large: 1
            case .medium: 0.85
            case .small: 0.7
            }
        }
    }

    public enum TitleAlignment: String, CaseIterable, Sendable {
        case leading, center

        public var title: String {
            switch self {
            case .leading: "左边"
            case .center: "居中"
            }
        }
    }
}
