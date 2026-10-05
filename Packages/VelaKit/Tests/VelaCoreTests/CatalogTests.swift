import Foundation
import Testing
@testable import VelaCore

struct CatalogRequestTests {
    private let today = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09

    @Test func trendingIgnoresFilter() {
        let request = CatalogRequest.make(shelf: .day, filter: CatalogFilter(genreID: 18), page: 2)
        #expect(request.path == "trending/all/day")
        #expect(request.parameters == ["page": "2"])
    }

    @Test func listShelfWithoutFilterUsesListEndpoint() {
        let request = CatalogRequest.make(shelf: .topMovies)
        #expect(request.path == "movie/top_rated")
    }

    @Test func topRatedWithGenreBecomesDiscoverByRating() {
        let request = CatalogRequest.make(shelf: .topMovies, filter: CatalogFilter(genreID: 18, year: 2020))
        #expect(request.path == "discover/movie")
        #expect(request.parameters["sort_by"] == "vote_average.desc")
        #expect(request.parameters["vote_count.gte"] == "300")
        #expect(request.parameters["with_genres"] == "18")
        #expect(request.parameters["primary_release_year"] == "2020")
    }

    @Test func animationKeepsGenreWhenFiltering() {
        let request = CatalogRequest.make(shelf: .animationTV, filter: CatalogFilter(genreID: 10765, sort: .newest))
        #expect(request.path == "discover/tv")
        #expect(request.parameters["with_genres"] == "16,10765")
        #expect(request.parameters["sort_by"] == "first_air_date.desc")
    }

    @Test func pageIsClamped() {
        #expect(CatalogRequest.make(shelf: .popularTV, page: 900).parameters["page"] == "500")
        #expect(CatalogRequest.make(shelf: .popularTV, page: 0).parameters["page"] == "1")
    }

    @Test func recentTopUsesRelativeDate() {
        let request = CatalogRequest.make(shelf: .recentTop, today: today)
        #expect(request.parameters["primary_release_date.gte"]?.hasPrefix("2023-") == true)
    }

    @Test func titleYearAndImage() {
        let title = CatalogTitle(tmdbID: 1, mediaType: .movie, title: "A", posterPath: "/p.jpg", date: "2019-05-01")
        #expect(title.year == 2019)
        #expect(CatalogImage.url(title.posterPath, size: .poster)?.absoluteString == "https://image.tmdb.org/t/p/w342/p.jpg")
        #expect(CatalogImage.url(nil, size: .poster) == nil)
    }

    @Test func everyCategoryHasShelves() {
        for category in CatalogCategory.allCases {
            #expect(!category.shelves.isEmpty)
        }
    }
}

struct CatalogIdentityTests {
    private func item(_ kind: MediaItem.Kind, _ ids: [String: String]) -> MediaItem {
        MediaItem(id: "x", serverID: "s", name: "同名", kind: kind, providerIDs: ids)
    }

    @Test func matchesByTMDBOrIMDb() {
        let identity = CatalogIdentity(mediaType: .movie, tmdbID: 42, imdbID: "tt0042")
        #expect(identity.matches(item(.movie, ["tmdb": "42"])))
        #expect(identity.matches(item(.movie, ["imdb": "TT0042"])))
        #expect(identity.providerQuery == ["Tmdb.42", "Imdb.tt0042"])
    }

    @Test func rejectsWrongTypeOrMissingIDs() {
        let identity = CatalogIdentity(mediaType: .tv, tmdbID: 42)
        #expect(!identity.matches(item(.movie, ["tmdb": "42"])))
        #expect(!identity.matches(item(.series, [:])))
        #expect(!identity.matches(item(.series, ["tmdb": "43"])))
        #expect(identity.matches(item(.series, ["tmdb": "42"])))
    }

    @Test func emptyIMDbIsIgnored() {
        #expect(CatalogIdentity(mediaType: .movie, tmdbID: 1, imdbID: "").providerQuery == ["Tmdb.1"])
    }
}
