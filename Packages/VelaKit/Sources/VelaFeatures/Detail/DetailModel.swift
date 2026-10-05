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
    /// 本地预告片与花絮（幕后、删减片段等）。
    private(set) var trailers: [MediaItem] = []
    private(set) var specialFeatures: [MediaItem] = []
    /// 多段文件的全部段（第一段为本条目）；单文件为空。
    private(set) var parts: [MediaItem] = []
    private(set) var actionError: String?
    /// 客户端合并进来的同一部电影的其他条目（见 `MediaItemMerger`），其媒体源作为额外版本供选择。
    private(set) var alternates: [ItemDetails] = []

    /// 一个可选版本：媒体源及其所属条目。合并条目的版本播放时要用所属条目的 id。
    struct SourceOption: Identifiable {
        var item: MediaItem
        var source: MediaSourceInfo
        var id: String { source.id }
    }

    /// 播放源选择（单集 / 电影）。
    var selectedSourceID: String?
    var selectedAudioIndex: Int?
    /// -1 表示关闭。
    var selectedSubtitleIndex: Int?

    init(item: MediaItem) {
        seed = item
    }

    var item: MediaItem { details?.item ?? seed }

    /// 本条目的媒体源在前，合并条目的媒体源在后。
    var sourceOptions: [SourceOption] {
        guard let details else { return [] }
        let own = details.mediaSources.map { SourceOption(item: details.item, source: $0) }
        let others = alternates.flatMap { alternate in alternate.mediaSources.map { SourceOption(item: alternate.item, source: $0) } }
        return own + others
    }

    private var selectedOption: SourceOption? {
        let options = sourceOptions
        return options.first { $0.id == selectedSourceID } ?? options.first
    }

    var selectedSource: MediaSourceInfo? { selectedOption?.source }

    /// 播放时使用的条目：选中合并条目的版本时为该条目，否则为当前条目。
    var playbackItem: MediaItem { selectedOption?.item ?? item }

    func load(client: MediaServerClient) async {
        do {
            let details = try await client.itemDetails(id: seed.id)
            self.details = details
            loadError = nil
            if !seed.mergedItemIDs.isEmpty {
                alternates = await loadAlternates(client: client)
            }
            resetSelections()
        } catch {
            loadError = error.localizedDescription
        }

        // 各分区相互独立：并发请求，哪个先返回先显示；单个失败只缺对应分区。
        let item = item
        let details = details
        await withTaskGroup(of: Section.self) { group in
            switch item.kind {
            case .series:
                group.addTask { .seasons((try? await client.seasons(seriesID: item.id)) ?? []) }
                group.addTask { .nextUp(try? await client.nextUp(seriesID: item.id)) }
            case .episode:
                if let seriesID = item.seriesID {
                    group.addTask { .siblings((try? await client.episodes(seriesID: seriesID, seasonID: item.seasonID)) ?? []) }
                }
            default:
                break
            }
            if item.kind.isPlayable, (item.partCount ?? 0) > 1 {
                group.addTask { .parts((try? await client.additionalParts(itemID: item.id)).map { [item] + $0 } ?? []) }
            }
            if item.kind == .movie || item.kind == .series {
                if (details?.localTrailerCount ?? 0) > 0 {
                    group.addTask { .trailers((try? await client.localTrailers(itemID: item.id)) ?? []) }
                }
                group.addTask { .features((try? await client.specialFeatures(itemID: item.id)) ?? []) }
            }
            if item.kind != .episode {
                group.addTask { .similar((try? await client.similarItems(itemID: item.id)) ?? []) }
            }
            for await section in group { apply(section) }
        }
    }

    private enum Section: Sendable {
        case seasons([MediaItem]), nextUp(MediaItem?), siblings([MediaItem]), parts([MediaItem])
        case trailers([MediaItem]), features([MediaItem]), similar([MediaItem])
    }

    private func apply(_ section: Section) {
        switch section {
        case .seasons(let value): seasons = value
        case .nextUp(let value): nextUp = value
        case .siblings(let value): siblingEpisodes = value
        case .parts(let value): parts = value
        case .trailers(let value): trailers = value
        case .features(let value): specialFeatures = value
        case .similar(let value): similar = value
        }
    }

    /// 合并条目逐个取详情；单个失败只是少一个版本，不影响页面。
    private func loadAlternates(client: MediaServerClient) async -> [ItemDetails] {
        let ids = seed.mergedItemIDs
        let results = await withTaskGroup(of: (Int, ItemDetails?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try? await client.itemDetails(id: id)) }
            }
            var collected: [(Int, ItemDetails?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
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
            subtitleStreamIndex: selectedSubtitleIndex,
            partIDs: parts.isEmpty ? nil : parts.map(\.id)
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
