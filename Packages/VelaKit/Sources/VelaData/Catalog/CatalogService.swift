import Foundation
import Observation
import VelaCore
import VelaNetwork

/// 发现 / 目录的数据入口：TMDB 凭据管理、目录条目与服务器库的精确匹配、跨服务器继续观看。
@MainActor
@Observable
public final class CatalogService {
    /// 用户在设置中填写的凭据（Keychain）；为空时回退到 Info.plist 的 `VelaTMDBAPIKey`（构建时注入）。
    public private(set) var userCredential: String
    @ObservationIgnored private let keychain: KeychainStore

    private static let keychainAccount = "tmdb.credential"
    private static let infoKey = "VelaTMDBAPIKey"

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        self.userCredential = (try? keychain.string(for: Self.keychainAccount)) ?? ""
    }

    private var bundledCredential: String {
        (Bundle.main.object(forInfoDictionaryKey: Self.infoKey) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    public var isConfigured: Bool { !userCredential.isEmpty || !bundledCredential.isEmpty }
    /// 正在使用构建时内置的凭据（用户未填写）。
    public var usesBundledCredential: Bool { userCredential.isEmpty && !bundledCredential.isEmpty }

    public var client: TMDBClient? {
        let credential = userCredential.isEmpty ? bundledCredential : userCredential
        return credential.isEmpty ? nil : TMDBClient(credential: credential)
    }

    /// 保存用户凭据；传空字符串清除（回退到内置凭据）。
    public func setCredential(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.remove(Self.keychainAccount)
        } else {
            try keychain.set(trimmed, for: Self.keychainAccount)
        }
        userCredential = trimmed
    }

    // MARK: - 匹配

    /// 某台服务器上与目录条目为同一作品的库条目。
    public struct Match: Identifiable, Sendable {
        public var serverID: String
        public var serverName: String
        public var item: MediaItem
        public var id: String { serverID + "/" + item.id }
    }

    public struct MatchResult: Sendable {
        public var matches: [Match]
        /// 查询失败的服务器（名称 + 原因）；失败不等于「没有资源」，界面需分别展示。
        public var failures: [(serverName: String, message: String)]
    }

    /// 在所有可访问的服务器中按 provider id 查找；活动服务器的结果排在前面。
    nonisolated public static func match(
        _ identity: CatalogIdentity,
        in sources: [FederatedSearchService.Source],
        activeServerID: String?
    ) async -> MatchResult {
        let outcomes = await withTaskGroup(of: (Int, Result<[MediaItem], any Error>).self) { group in
            var next = 0
            var collected: [(Int, Result<[MediaItem], any Error>)] = []
            func enqueue() {
                guard next < sources.count else { return }
                let index = next
                let client = sources[index].client
                next += 1
                group.addTask {
                    do {
                        let page = try await client.items(ItemQuery(
                            includeItemTypes: [identity.mediaType == .movie ? "Movie" : "Series"],
                            recursive: true,
                            limit: 100,
                            anyProviderIDs: identity.providerQuery
                        ))
                        return (index, .success(page.items))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(FederatedSearchService.maxConcurrentSources, sources.count) { enqueue() }
            for await outcome in group {
                collected.append(outcome)
                enqueue()
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        var matches: [Match] = []
        var failures: [(String, String)] = []
        for (index, outcome) in outcomes {
            let source = sources[index]
            switch outcome {
            case .success(let items):
                matches += items.filter(identity.matches).map { Match(serverID: source.id, serverName: source.name, item: $0) }
            case .failure(let error):
                failures.append((source.name, error.localizedDescription))
            }
        }
        matches.sort { ($0.serverID == activeServerID ? 0 : 1) < ($1.serverID == activeServerID ? 0 : 1) }
        return MatchResult(matches: matches, failures: failures)
    }

    // MARK: - 跨服务器继续观看

    /// 各服务器的继续观看合并，按最近播放时间倒序。单个服务器失败时跳过（发现页只是聚合视图）。
    nonisolated public static func federatedResume(in sources: [FederatedSearchService.Source], limitPerSource: Int = 12) async -> [Match] {
        await withTaskGroup(of: [Match].self) { group in
            for source in sources {
                group.addTask {
                    let items = (try? await source.client.resume(limit: limitPerSource).items) ?? []
                    return items.map { Match(serverID: source.id, serverName: source.name, item: $0) }
                }
            }
            var all: [Match] = []
            for await batch in group { all += batch }
            return all.sorted { ($0.item.lastPlayedAt ?? .distantPast) > ($1.item.lastPlayedAt ?? .distantPast) }
        }
    }
}
