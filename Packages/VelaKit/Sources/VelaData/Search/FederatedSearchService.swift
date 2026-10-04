import Foundation
import VelaCore
import VelaNetwork

/// 一个搜索源（当前为已登录服务器；TMDB / 豆瓣接入后同样实现为 source）的结果。
public struct FederatedSearchSection: Identifiable, Sendable {
    public var id: String { sourceID }
    public var sourceID: String
    public var sourceName: String
    public var result: Result<[MediaItem], SearchSourceError>
}

public struct SearchSourceError: Error, Sendable {
    public var message: String
}

/// 多服务器聚合搜索：并发查询、限制同时在途的请求数，单个源失败只影响自己的分区。
public struct FederatedSearchService: Sendable {
    /// 同时在途的服务器请求上限；保存的服务器较多时避免瞬间占满连接与图片队列。
    public static let maxConcurrentSources = 4

    public struct Source: Sendable {
        public var id: String
        public var name: String
        public var client: MediaServerClient

        public init(id: String, name: String, client: MediaServerClient) {
            self.id = id
            self.name = name
            self.client = client
        }
    }

    public init() {}

    /// 返回顺序与 `sources` 一致，便于界面稳定展示。调用方取消任务时，未完成的请求随之取消。
    public func search(_ term: String, in sources: [Source], limitPerSource: Int = 40) async -> [FederatedSearchSection] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !sources.isEmpty else { return [] }

        var sections = [FederatedSearchSection?](repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, FederatedSearchSection).self) { group in
            var next = 0
            func enqueue() {
                guard next < sources.count else { return }
                let index = next
                let source = sources[index]
                next += 1
                group.addTask {
                    let result: Result<[MediaItem], SearchSourceError>
                    do {
                        result = .success(try await source.client.search(query, limit: limitPerSource))
                    } catch {
                        result = .failure(SearchSourceError(message: error.localizedDescription))
                    }
                    return (index, FederatedSearchSection(sourceID: source.id, sourceName: source.name, result: result))
                }
            }
            for _ in 0..<min(Self.maxConcurrentSources, sources.count) { enqueue() }
            for await (index, section) in group {
                sections[index] = section
                enqueue()
            }
        }
        return sections.compactMap { $0 }
    }
}
