import Foundation
import Testing
import VelaCore
@testable import VelaNetwork

/// 用固定响应替代网络，验证 TMDB 解码与鉴权方式。
final class TMDBStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct TMDBClientTests {
    private func client(_ credential: String) -> TMDBClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TMDBStubProtocol.self]
        return TMDBClient(credential: credential, session: URLSession(configuration: configuration))
    }

    @Test func decodesMixedTrendingAndDropsPeople() async throws {
        TMDBStubProtocol.body = Data("""
        {"page":1,"total_pages":3,"results":[
          {"id":1,"media_type":"movie","title":"电影","release_date":"2024-01-02","poster_path":"/a.jpg","vote_average":7.5},
          {"id":2,"media_type":"tv","name":"剧集","first_air_date":"","vote_average":0},
          {"id":3,"media_type":"person","name":"某人"}
        ]}
        """.utf8)
        let page = try await client("0123456789abcdef0123456789abcdef").page(CatalogRequest.make(shelf: .day), mediaType: nil)
        #expect(page.results.map(\.id) == ["movie/1", "tv/2"])
        #expect(page.results[0].year == 2024)
        #expect(page.results[1].date == nil)
        #expect(page.results[1].voteAverage == nil)
        #expect(page.totalPages == 3)
        let query = TMDBStubProtocol.lastRequest?.url?.query() ?? ""
        #expect(query.contains("api_key="))
        #expect(query.contains("language=zh-CN"))
    }

    @Test func typedListGetsDefaultTypeAndBearerToken() async throws {
        TMDBStubProtocol.body = Data(#"{"page":1,"total_pages":1,"results":[{"id":9,"name":"动画"}]}"#.utf8)
        let token = String(repeating: "x", count: 60)
        let page = try await client(token).page(CatalogRequest.make(shelf: .animationTV), mediaType: .tv)
        #expect(page.results.first?.mediaType == .tv)
        #expect(TMDBStubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(TMDBStubProtocol.lastRequest?.url?.query()?.contains("api_key") == false)
    }

    @Test func detailReadsExternalIDs() async throws {
        TMDBStubProtocol.body = Data("""
        {"id":5,"title":"T","genres":[{"id":18,"name":"剧情"}],"runtime":120,
         "external_ids":{"imdb_id":"tt0000005","tvdb_id":null},
         "credits":{"cast":[{"id":1,"name":"演员","character":"角色","profile_path":"/c.jpg"}]},
         "recommendations":{"results":[{"id":6,"title":"R"}]}}
        """.utf8)
        let detail = try await client("0123456789abcdef0123456789abcdef").detail(.movie, id: 5)
        #expect(detail.imdbID == "tt0000005")
        #expect(detail.genres.first?.name == "剧情")
        #expect(detail.cast.first?.character == "角色")
        #expect(detail.recommendations.first?.mediaType == .movie)
    }

    @Test func missingKeyFailsFast() async {
        await #expect(throws: TMDBClient.TMDBError.self) {
            try await client("  ").genres(.movie)
        }
    }
}

struct MoviePilotParsingTests {
    @Test func normalizesBaseURL() {
        #expect(MoviePilotClient.normalize("https://mp.example.com/api/v1/")?.absoluteString == "https://mp.example.com")
        #expect(MoviePilotClient.normalize("ftp://mp.example.com") == nil)
        #expect(MoviePilotClient.normalize("https://user:pw@mp.example.com") == nil)
    }

    @Test func parsesMixedTypeSubscriptionRow() {
        let row: [String: Any] = ["id": "12", "name": "剧", "type": "电视剧", "season": 2, "tmdbid": "99", "state": "R", "total_episode": 0]
        let record = MoviePilotClient.parseSubscription(row)
        #expect(record?.id == 12)
        #expect(record?.season == 2)
        #expect(record?.tmdbID == 99)
        #expect(record?.totalEpisodes == nil)
        #expect(MoviePilotClient.parseSubscription(["name": "无 id"]) == nil)
    }

    @Test func movieHasNoSeason() {
        let record = MoviePilotClient.parseSubscription(["id": 1, "type": "电影", "season": 1, "tmdbid": 5])
        #expect(record?.mediaType == .movie)
        #expect(record?.season == nil)
    }
}
