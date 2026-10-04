import Foundation
import Observation
import VelaCore
import VelaNetwork

/// 详情页数据：主信息先到先显示，季 / 集 / 类似作品各自独立加载，单项失败不影响其余分区。
@MainActor
@Observable
final class DetailModel {
    let seed: MediaItem
    private(set) var details: ItemDetails?
    private(set) var loadError: String?
    private(set) var seasons: [MediaItem] = []
    /// 剧集：下一集；单集：所在季的全部单集。
    private(set) var nextUp: MediaItem?
    private(set) var siblingEpisodes: [MediaItem] = []
    private(set) var similar: [MediaItem] = []
    private(set) var actionError: String?

    /// 播放源选择（单集 / 电影）。
    var selectedSourceID: String?
    var selectedAudioIndex: Int?
    /// -1 表示关闭。
    var selectedSubtitleIndex: Int?

    init(item: MediaItem) {
        seed = item
    }

    var item: MediaItem { details?.item ?? seed }

    var selectedSource: MediaSourceInfo? {
        guard let sources = details?.mediaSources, !sources.isEmpty else { return nil }
        return sources.first { $0.id == selectedSourceID } ?? sources.first
    }

    func load(client: MediaServerClient) async {
        do {
            let details = try await client.itemDetails(id: seed.id)
            self.details = details
            loadError = nil
            resetSelections()
        } catch {
            loadError = error.localizedDescription
        }

        let item = item
        switch item.kind {
        case .series:
            async let seasons = capture { try await client.seasons(seriesID: item.id) }
            async let next = capture { try await client.nextUp(seriesID: item.id) }
            if case .success(let value) = await seasons { self.seasons = value }
            if case .success(let value) = await next { self.nextUp = value }
        case .episode:
            if let seriesID = item.seriesID,
               case .success(let episodes) = await capture({ try await client.episodes(seriesID: seriesID, seasonID: item.seasonID) }) {
                siblingEpisodes = episodes
            }
        default:
            break
        }
        if item.kind != .episode, case .success(let value) = await capture({ try await client.similarItems(itemID: item.id) }) {
            similar = value
        }
    }

    /// 选择变化时重置为该版本的服务器默认音轨 / 字幕。
    func resetSelections() {
        guard let source = selectedSource else { return }
        selectedSourceID = source.id
        selectedAudioIndex = source.defaultAudioStreamIndex ?? source.audioStreams.first?.index
        if let index = source.defaultSubtitleStreamIndex, index >= 0 {
            selectedSubtitleIndex = index
        } else {
            selectedSubtitleIndex = -1
        }
    }

    var playbackOptions: PlaybackRequest.Options {
        PlaybackRequest.Options(
            mediaSourceID: selectedSourceID,
            audioStreamIndex: selectedAudioIndex,
            subtitleStreamIndex: selectedSubtitleIndex
        )
    }

    // MARK: - 已看 / 收藏

    func togglePlayed(client: MediaServerClient) async {
        let target = !item.isPlayed
        await mutate { try await client.setPlayed(itemID: self.item.id, target) } apply: { $0.isPlayed = target; if target { $0.playbackPositionTicks = 0 } }
    }

    func toggleFavorite(client: MediaServerClient) async {
        let target = !item.isFavorite
        await mutate { try await client.setFavorite(itemID: self.item.id, target) } apply: { $0.isFavorite = target }
    }

    /// 先请求服务器，成功后再更新界面，不做乐观更新以免失败时状态错乱。
    private func mutate(_ request: @escaping () async throws -> Void, apply: (inout MediaItem) -> Void) async {
        do {
            try await request()
            actionError = nil
            if var details {
                apply(&details.item)
                self.details = details
            }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// 外部链接：只根据 provider id 生成，没有对应 id 时不显示。
struct ExternalLink: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var url: URL

    static func links(for item: MediaItem) -> [ExternalLink] {
        let ids = item.providerIDs
        var links: [ExternalLink] = []
        func add(_ name: String, _ raw: String?) {
            if let raw, let url = URL(string: raw) { links.append(.init(name: name, url: url)) }
        }
        if let douban = ids["douban"] { add("豆瓣", "https://movie.douban.com/subject/\(douban)/") }
        if let imdb = ids["imdb"] { add("IMDb", "https://www.imdb.com/title/\(imdb)/") }
        if let tmdb = ids["tmdb"] {
            switch item.kind {
            case .movie: add("TMDB", "https://www.themoviedb.org/movie/\(tmdb)")
            case .series: add("TMDB", "https://www.themoviedb.org/tv/\(tmdb)")
            default: break // 单集的 TMDB id 不是剧集 id，无法直接构造页面地址。
            }
        }
        if let tvdb = ids["tvdb"] {
            switch item.kind {
            case .series: add("TheTVDB", "https://thetvdb.com/dereferrer/series/\(tvdb)")
            case .episode: add("TheTVDB", "https://thetvdb.com/dereferrer/episode/\(tvdb)")
            case .movie: add("TheTVDB", "https://thetvdb.com/dereferrer/movie/\(tvdb)")
            default: break
            }
        }
        if let bangumi = ids["bangumi"] { add("Bangumi", "https://bgm.tv/subject/\(bangumi)") }
        return links
    }
}

/// 详情页数值格式。
enum MediaFormat {
    static func bitrate(_ bitsPerSecond: Int?) -> String? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        let mbps = Double(bitsPerSecond) / 1_000_000
        return mbps >= 1 ? String(format: "%.1f Mbps", mbps) : "\(bitsPerSecond / 1000) kbps"
    }

    static func size(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func runtime(_ ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        return Duration.seconds(Ticks.seconds(ticks)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func resolution(_ stream: MediaStreamInfo?) -> String? {
        guard let height = stream?.height, height > 0 else { return nil }
        let label = switch height {
        case 2000...: "4K"
        case 1000..<2000: "1080p"
        case 700..<1000: "720p"
        default: "\(height)p"
        }
        return label
    }

    /// 媒体源摘要，例如「1080p H264 · 2.3 GB · 8.0 Mbps」。
    static func sourceSummary(_ source: MediaSourceInfo) -> String {
        let video = source.videoStream
        let codec = video?.codec?.uppercased()
        let range = video?.videoRangeType.flatMap { $0 == "SDR" ? nil : $0 }
        let head = [resolution(video), codec, range].compactMap { $0 }.joined(separator: " ")
        return [head.isEmpty ? nil : head, size(source.size), bitrate(source.bitrate)].compactMap { $0 }.joined(separator: " · ")
    }
}
