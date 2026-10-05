import Testing
@testable import VelaCore

struct MediaItemMergerTests {
    private func movie(_ id: String, tmdb: String? = nil, imdb: String? = nil, played: Bool = false, server: String = "s") -> MediaItem {
        var ids: [String: String] = [:]
        ids["tmdb"] = tmdb
        ids["imdb"] = imdb
        return MediaItem(id: id, serverID: server, name: "Movie \(id)", kind: .movie, isPlayed: played, providerIDs: ids)
    }

    @Test func mergesSameTMDBKeepingFirstPosition() {
        let merged = MediaItemMerger.merge([movie("a", tmdb: "1"), movie("b", tmdb: "2"), movie("c", tmdb: "1", played: true)])
        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged[0].mergedItemIDs == ["c"])
        #expect(merged[0].versionCount == 2)
        #expect(merged[0].isPlayed)
    }

    @Test func fallsBackToIMDb() {
        let merged = MediaItemMerger.merge([movie("a", imdb: "tt1"), movie("b", imdb: "tt1")])
        #expect(merged.count == 1)
    }

    @Test func itemsWithoutIDsAreKept() {
        #expect(MediaItemMerger.merge([movie("a"), movie("b")]).count == 2)
    }

    @Test func seriesAreNeverMerged() {
        let series = MediaItem(id: "x", serverID: "s", name: "S", kind: .series, providerIDs: ["tmdb": "9"])
        let other = MediaItem(id: "y", serverID: "s", name: "S", kind: .series, providerIDs: ["tmdb": "9"])
        #expect(MediaItemMerger.merge([series, other]).count == 2)
    }

    @Test func differentServersStaySeparate() {
        #expect(MediaItemMerger.merge([movie("a", tmdb: "1", server: "s1"), movie("b", tmdb: "1", server: "s2")]).count == 2)
    }

    @Test func duplicatePagesAreIdempotent() {
        let once = MediaItemMerger.merge([movie("a", tmdb: "1"), movie("c", tmdb: "1")])
        let twice = MediaItemMerger.merge(once + [movie("c", tmdb: "1")])
        #expect(twice[0].mergedItemIDs == ["c"])
    }

    @Test func serverVersionsCount() {
        var item = movie("a", tmdb: "1")
        item.mediaSourceCount = 3
        #expect(item.versionCount == 3)
    }
}
