import Foundation
import Observation
import VelaCore
import VelaNetwork

/// 订阅与日历。MoviePilot 为订阅真相源（每次从服务端读取，不缓存副本）；未连接或失败时日历回退到 Bangumi 公开放送。
///
/// 地址与用户名存 UserDefaults；access token 存 Keychain（按地址区分账号），不落普通存储。
@MainActor
@Observable
public final class SubscriptionService {
    public private(set) var url: String
    public private(set) var username: String
    public private(set) var isConnected: Bool
    /// 删除订阅时同步删除 MoviePilot 上的订阅（关闭后只读）。
    public var allowsRemoval: Bool {
        didSet { defaults.set(allowsRemoval, forKey: Key.allowsRemoval) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore

    private enum Key {
        static let url = "moviepilot.url"
        static let username = "moviepilot.username"
        static let allowsRemoval = "moviepilot.allowsRemoval"
    }

    /// 日历中同时查询的订阅数上限，避免订阅多时瞬间打满 MoviePilot。
    private static let calendarConcurrency = 3

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        let url = defaults.string(forKey: Key.url) ?? ""
        self.url = url
        self.username = defaults.string(forKey: Key.username) ?? ""
        self.allowsRemoval = defaults.object(forKey: Key.allowsRemoval) as? Bool ?? true
        self.isConnected = !url.isEmpty && ((try? keychain.string(for: Self.account(url))) ?? nil) != nil
    }

    private static func account(_ url: String) -> String { "moviepilot:\(url)" }

    private func client() throws -> MoviePilotClient {
        guard isConnected, let token = try keychain.string(for: Self.account(url)) else {
            throw MoviePilotClient.MoviePilotError.loginRequired
        }
        return try MoviePilotClient(baseURL: url, token: token)
    }

    // MARK: - 连接

    /// 登录并读取一次订阅列表确认可用后才保存。
    public func connect(url rawURL: String, username: String, password: String, otp: String = "") async throws {
        let anonymous = try MoviePilotClient(baseURL: rawURL)
        let normalized = anonymous.baseURL.absoluteString
        let token = try await anonymous.login(username: username.trimmingCharacters(in: .whitespaces), password: password, otp: otp)
        _ = try await MoviePilotClient(baseURL: normalized, token: token).subscriptions()
        if !url.isEmpty, url != normalized { try? keychain.remove(Self.account(url)) }
        try keychain.set(token, for: Self.account(normalized))
        url = normalized
        self.username = username.trimmingCharacters(in: .whitespaces)
        defaults.set(normalized, forKey: Key.url)
        defaults.set(self.username, forKey: Key.username)
        isConnected = true
    }

    public func disconnect() {
        try? keychain.remove(Self.account(url))
        isConnected = false
    }

    // MARK: - 订阅

    public func subscriptions() async throws -> [SubscriptionRecord] {
        try await client().subscriptions()
    }

    /// 目录条目已订阅的季（电影用 0 表示已订阅）。
    public func subscribedSeasons(of title: CatalogTitle) async throws -> Set<Int> {
        let records = try await subscriptions().filter { $0.tmdbID == title.tmdbID && $0.mediaType == title.mediaType }
        return Set(records.map { $0.mediaType == .movie ? 0 : ($0.season ?? 0) })
    }

    /// 订阅 / 取消订阅。剧集必须指定季；取消时只在唯一匹配一条订阅时删除，避免误删。
    public func setSubscription(_ title: CatalogTitle, season: Int?, subscribed: Bool) async throws {
        guard title.mediaType == .movie || (season ?? 0) > 0 else {
            throw MoviePilotClient.MoviePilotError.rejected("请选择要订阅的季")
        }
        let client = try client()
        let matches = try await client.subscriptions().filter {
            $0.tmdbID == title.tmdbID && $0.mediaType == title.mediaType && $0.season == (title.mediaType == .movie ? nil : season)
        }
        if subscribed {
            guard matches.isEmpty else { return }
            try await client.addSubscription(title, season: title.mediaType == .movie ? nil : season)
        } else {
            guard allowsRemoval else { throw MoviePilotClient.MoviePilotError.rejected("已关闭同步删除订阅") }
            guard matches.count == 1 else { throw MoviePilotClient.MoviePilotError.rejected("订阅已在服务端变化，请到「我的订阅」中单独管理") }
            try await client.removeSubscription(id: matches[0].id)
        }
    }

    public func remove(_ record: SubscriptionRecord) async throws {
        guard allowsRemoval else { throw MoviePilotClient.MoviePilotError.rejected("已关闭同步删除订阅") }
        try await client().removeSubscription(id: record.id)
    }

    public func searchDouban(_ query: String) async throws -> [DoubanTitle] {
        try await client().searchDouban(query)
    }

    // MARK: - 日历

    /// 已连接 MoviePilot 时按订阅生成日历；失败则回退到 Bangumi 并附带原因。
    public func calendar(today: Date = .now) async -> Result<CalendarFeed, any Error> {
        if isConnected {
            do {
                return .success(try await moviePilotCalendar(today: today))
            } catch {
                return await bangumiCalendar(today: today).map {
                    var feed = $0
                    feed.warning = "MoviePilot 日历加载失败，已显示 Bangumi 放送：\(error.localizedDescription)"
                    return feed
                }
            }
        }
        return await bangumiCalendar(today: today)
    }

    private func moviePilotCalendar(today: Date) async throws -> CalendarFeed {
        let client = try client()
        let records = try await client.subscriptions()
        let results = await withTaskGroup(of: Result<[CalendarEntry], any Error>.self) { group in
            var iterator = records.makeIterator()
            func enqueue() {
                guard let record = iterator.next() else { return }
                group.addTask { await Self.entries(for: record, client: client, today: today) }
            }
            for _ in 0..<Self.calendarConcurrency { enqueue() }
            var collected: [Result<[CalendarEntry], any Error>] = []
            for await result in group {
                collected.append(result)
                enqueue()
            }
            return collected
        }
        let failures = results.compactMap { result -> String? in
            if case .failure(let error) = result { return error.localizedDescription }
            return nil
        }
        if !results.isEmpty, failures.count == results.count, let first = failures.first {
            throw MoviePilotClient.MoviePilotError.rejected(first)
        }
        var seen: Set<String> = []
        let entries = results.flatMap { (try? $0.get()) ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date < $1.date }
        let warning = failures.isEmpty ? nil : "\(failures.count) 个订阅的播出信息加载失败"
        return CalendarFeed(source: "MoviePilot", entries: entries, warning: warning)
    }

    nonisolated private static func entries(for record: SubscriptionRecord, client: MoviePilotClient, today: Date) async -> Result<[CalendarEntry], any Error> {
        guard let catalog = record.catalogTitle else { return .success([]) }
        do {
            switch catalog.mediaType {
            case .movie:
                guard let date = CalendarRules.day(from: try await client.movieReleaseDate(tmdbID: catalog.tmdbID)),
                      CalendarRules.isInWindow(date, today: today) else { return .success([]) }
                return .success([CalendarEntry(id: "mp:\(record.id)", title: record.name, posterURL: record.posterURL, date: date, catalog: catalog)])
            case .tv:
                guard let season = record.season else { return .success([]) }
                let episodes = try await client.episodes(tmdbID: catalog.tmdbID, season: season, episodeGroup: record.episodeGroup)
                return .success(episodes.compactMap { episode in
                    guard let date = CalendarRules.day(from: episode.airDate), CalendarRules.isInWindow(date, today: today) else { return nil }
                    return CalendarEntry(
                        id: "mp:\(record.id):\(episode.number ?? 0):\(episode.airDate ?? "")",
                        title: record.name, posterURL: record.posterURL, date: date, catalog: catalog,
                        season: season, episode: episode.number, episodeName: episode.name
                    )
                })
            }
        } catch {
            return .failure(error)
        }
    }

    private func bangumiCalendar(today: Date) async -> Result<CalendarFeed, any Error> {
        do {
            let subjects = try await BangumiClient().calendar()
            let entries = subjects.compactMap { subject -> CalendarEntry? in
                guard let date = CalendarRules.nextDate(forBangumiWeekday: subject.weekday, today: today) else { return nil }
                return CalendarEntry(
                    id: "bgm:\(subject.id)",
                    title: subject.nameCN?.isEmpty == false ? subject.nameCN! : subject.name,
                    originalTitle: subject.name,
                    posterURL: subject.imageURL,
                    date: date,
                    sourceURL: URL(string: "https://bgm.tv/subject/\(subject.id)")
                )
            }
            return .success(CalendarFeed(source: "Bangumi", entries: entries.sorted { $0.date < $1.date }))
        } catch {
            return .failure(error)
        }
    }
}
