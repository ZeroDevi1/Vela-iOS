import Testing
@testable import VelaCore

/// 搜索相关度排序：与 Android 版相同的匹配等级。
struct SearchRankingTests {
    @Test func matchLevels() {
        #expect(SearchRanking.match(text: "Spider-Man", query: "spiderman") == .exact)
        #expect(SearchRanking.match(text: "流浪地球", query: "流浪地球") == .exact)
        #expect(SearchRanking.match(text: "流浪地球 2", query: "流浪地球") == .phrase)
        #expect(SearchRanking.match(text: "The Dark Knight Rises", query: "knight dark") == .allWords)
        #expect(SearchRanking.match(text: "Breaking Bad", query: "zzz") == nil)
    }

    @Test func rankingDropsNonMatchesAndKeepsOrderWithinLevel() {
        let titles = ["Avatar: The Way of Water", "Avatar", "Titanic", "Avatar 3"]
        let ranked = SearchRanking.rank(titles, query: "Avatar") { [$0] }
        #expect(ranked == ["Avatar", "Avatar: The Way of Water", "Avatar 3"])
    }
}
