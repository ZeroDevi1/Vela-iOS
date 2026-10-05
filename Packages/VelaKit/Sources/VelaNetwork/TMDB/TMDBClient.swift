import Foundation
import VelaCore

/// TMDB v3 接口。值类型、无状态，可在任意并发上下文使用。
///
/// 凭据两种格式：v3 API Key（32 位十六进制，走 `api_key` 参数）与 v4 Read Access Token（JWT，走 Bearer 头）。
/// 请求地址带 v3 key 时不写日志，避免泄露。
public struct TMDBClient: Sendable {
    public enum TMDBError: LocalizedError {
        case missingKey
        case invalidKey
        case http(Int)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .missingKey: "未配置 TMDB API Key，请在设置中填写"
            case .invalidKey: "TMDB API Key 无效"
            case .http(let status): "TMDB 返回错误（HTTP \(status)）"
            case .transport(let message): message
            }
        }
    }

    public struct Page: Sendable {
        public var results: [CatalogTitle]
        public var page: Int
        public var totalPages: Int
    }

    public struct Genre: Identifiable, Hashable, Sendable {
        public var id: Int
        public var name: String
    }

    public struct CastMember: Identifiable, Hashable, Sendable {
        public var id: Int
        public var name: String
        public var character: String?
        public var profilePath: String?
    }

    /// 目录详情（列表接口之外补充的字段）。
    public struct Detail: Sendable {
        public var title: CatalogTitle
        public var genres: [Genre]
        public var tagline: String?
        /// 电影时长（分钟）。
        public var runtime: Int?
        public var numberOfSeasons: Int?
        public var status: String?
        public var imdbID: String?
        public var tvdbID: Int?
        public var cast: [CastMember]
        public var recommendations: [CatalogTitle]
    }

    private let credential: String
    private let session: URLSession
    private static let baseURL = URL(string: "https://api.themoviedb.org/3/")!
    private static let language = "zh-CN"

    public init(credential: String, session: URLSession = .shared) {
        self.credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    private var usesBearer: Bool { credential.count > 40 }

    // MARK: - 接口

    public func page(_ request: CatalogRequest, mediaType: CatalogTitle.MediaType?) async throws -> Page {
        let dto: PageDTO = try await get(request.path, request.parameters)
        return Page(
            results: dto.results.compactMap { $0.toTitle(defaultType: mediaType) },
            page: dto.page ?? 1,
            totalPages: min(dto.totalPages ?? 1, 500)
        )
    }

    public func genres(_ type: CatalogTitle.MediaType) async throws -> [Genre] {
        let dto: GenresDTO = try await get("genre/\(type.rawValue)/list", [:])
        return dto.genres.map { Genre(id: $0.id, name: $0.name) }
    }

    public func detail(_ type: CatalogTitle.MediaType, id: Int) async throws -> Detail {
        let dto: DetailDTO = try await get("\(type.rawValue)/\(id)", ["append_to_response": "external_ids,credits,recommendations"])
        guard let title = dto.base.toTitle(defaultType: type) else { throw TMDBError.http(404) }
        return Detail(
            title: title,
            genres: (dto.genres ?? []).map { Genre(id: $0.id, name: $0.name) },
            tagline: dto.tagline?.isEmpty == false ? dto.tagline : nil,
            runtime: dto.runtime,
            numberOfSeasons: dto.numberOfSeasons,
            status: dto.status,
            imdbID: dto.externalIDs?.imdbID ?? dto.imdbID,
            tvdbID: dto.externalIDs?.tvdbID,
            cast: (dto.credits?.cast ?? []).prefix(20).map {
                CastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profilePath)
            },
            recommendations: (dto.recommendations?.results ?? []).compactMap { $0.toTitle(defaultType: type) }
        )
    }

    /// 按 IMDb id 查找（豆瓣条目只有 IMDb id 时换算 TMDB 身份）。
    public func find(imdbID: String) async throws -> [CatalogTitle] {
        guard imdbID.range(of: #"^tt[0-9]+$"#, options: .regularExpression) != nil else { return [] }
        let dto: FindDTO = try await get("find/\(imdbID)", ["external_source": "imdb_id"])
        return dto.movieResults.compactMap { $0.toTitle(defaultType: .movie) } + dto.tvResults.compactMap { $0.toTitle(defaultType: .tv) }
    }

    public func search(_ query: String) async throws -> [CatalogTitle] {
        let dto: PageDTO = try await get("search/multi", ["query": query, "include_adult": "false"])
        return dto.results.compactMap { $0.toTitle(defaultType: nil) }
    }

    // MARK: - 请求

    private func get<T: Decodable>(_ path: String, _ parameters: [String: String]) async throws -> T {
        guard !credential.isEmpty else { throw TMDBError.missingKey }
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        var query = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        query.append(.init(name: "language", value: Self.language))
        if !usesBearer { query.append(.init(name: "api_key", value: credential)) }
        components.queryItems = query.sorted { $0.name < $1.name }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearer { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TMDBError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw TMDBError.http(-1) }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw TMDBError.invalidKey
        default:
            Log.network.error("TMDB HTTP \(http.statusCode, privacy: .public) \(path, privacy: .public)")
            throw TMDBError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

// MARK: - DTO

private struct PageDTO: Decodable {
    var page: Int?
    var results: [TitleDTO]
    var totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
    }
}

private struct TitleDTO: Decodable {
    var id: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var genreIDs: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case originalTitle = "original_title"
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case genreIDs = "genre_ids"
    }

    /// 趋势榜等混合列表带 `media_type`，类型固定的列表不带，用 `defaultType` 补上；人物等其他类型丢弃。
    func toTitle(defaultType: CatalogTitle.MediaType?) -> CatalogTitle? {
        let type = mediaType.flatMap(CatalogTitle.MediaType.init(rawValue:)) ?? (mediaType == nil ? defaultType : nil)
        guard let type, id > 0, let name = (title ?? name), !name.isEmpty else { return nil }
        let date = (releaseDate ?? firstAirDate).flatMap { $0.isEmpty ? nil : $0 }
        return CatalogTitle(
            tmdbID: id,
            mediaType: type,
            title: name,
            originalTitle: originalTitle ?? originalName,
            overview: overview?.isEmpty == false ? overview : nil,
            posterPath: posterPath,
            backdropPath: backdropPath,
            date: date,
            voteAverage: (voteAverage ?? 0) > 0 ? voteAverage : nil,
            genreIDs: genreIDs ?? []
        )
    }
}

private struct FindDTO: Decodable {
    var movieResults: [TitleDTO]
    var tvResults: [TitleDTO]

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}

private struct GenresDTO: Decodable {
    struct GenreDTO: Decodable { var id: Int; var name: String }
    var genres: [GenreDTO]
}

private struct DetailDTO: Decodable {
    struct ExternalIDs: Decodable {
        var imdbID: String?
        var tvdbID: Int?
        enum CodingKeys: String, CodingKey { case imdbID = "imdb_id", tvdbID = "tvdb_id" }
    }

    struct Credits: Decodable {
        struct Cast: Decodable {
            var id: Int
            var name: String
            var character: String?
            var profilePath: String?
            enum CodingKeys: String, CodingKey { case id, name, character, profilePath = "profile_path" }
        }
        var cast: [Cast]?
    }

    struct Recommendations: Decodable { var results: [TitleDTO]? }

    var base: TitleDTO
    var genres: [GenresDTO.GenreDTO]?
    var tagline: String?
    var runtime: Int?
    var numberOfSeasons: Int?
    var status: String?
    var imdbID: String?
    var externalIDs: ExternalIDs?
    var credits: Credits?
    var recommendations: Recommendations?

    enum CodingKeys: String, CodingKey {
        case genres, tagline, runtime, status, credits, recommendations
        case numberOfSeasons = "number_of_seasons"
        case imdbID = "imdb_id"
        case externalIDs = "external_ids"
    }

    init(from decoder: any Decoder) throws {
        base = try TitleDTO(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try c.decodeIfPresent([GenresDTO.GenreDTO].self, forKey: .genres)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        numberOfSeasons = try c.decodeIfPresent(Int.self, forKey: .numberOfSeasons)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        imdbID = try c.decodeIfPresent(String.self, forKey: .imdbID)
        externalIDs = try? c.decodeIfPresent(ExternalIDs.self, forKey: .externalIDs)
        credits = try? c.decodeIfPresent(Credits.self, forKey: .credits)
        recommendations = try? c.decodeIfPresent(Recommendations.self, forKey: .recommendations)
    }
}
