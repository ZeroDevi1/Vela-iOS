import Foundation
import Testing
import VelaCore
@testable import VelaNetwork

/// 「为你推荐」分组标题 / 合并与 Wikidata 获奖作品解析。
struct DiscoverFeedTests {
    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, serverID: "s", name: id, kind: .movie)
    }

    @Test func recommendationTitlesAndMerge() {
        let a = MediaRecommendation(kind: "SimilarToRecentlyPlayed", baselineName: "盗梦空间", items: [item("1"), item("2")])
        let b = MediaRecommendation(kind: "SimilarToRecentlyPlayed", baselineName: "盗梦空间", items: [item("2"), item("3")])
        let c = MediaRecommendation(kind: "HasLikedActor", baselineName: "  ", items: [item("4")])
        #expect(a.title == "因为你看过《盗梦空间》")
        #expect(MediaRecommendation(kind: "HasLikedDirector", baselineName: "诺兰", items: []).title == "诺兰 执导")
        let merged = MediaRecommendation.merged([a, b, c])
        #expect(merged.count == 1)
        #expect(merged[0].items.map(\.id) == ["1", "2", "3"])
    }

    @Test func parsesWikidataBindings() throws {
        let json = """
        {"results":{"bindings":[
          {"cat":{"value":"http://www.wikidata.org/entity/Q102427"},"tmdb":{"value":"496243"},"type":{"value":"movie"},"year":{"value":"2019"}},
          {"cat":{"value":"http://www.wikidata.org/entity/Q102427"},"tmdb":{"value":"abc"},"type":{"value":"movie"}},
          {"cat":{"value":"http://www.wikidata.org/entity/Q1255198"},"tmdb":{"value":"1396"},"type":{"value":"tv"}}
        ]}}
        """
        let grouped = try WikidataAwardsClient.parse(Data(json.utf8))
        #expect(grouped["Q102427"] == [AwardTitleRef(tmdbID: 496243, mediaType: .movie, year: 2019)])
        #expect(grouped["Q1255198"]?.first?.mediaType == .tv)
    }
}
