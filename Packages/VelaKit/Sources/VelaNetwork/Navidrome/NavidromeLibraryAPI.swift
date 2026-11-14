import Foundation

public struct NavidromeFolder: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
}

public struct NavidromeUser: Decodable, Identifiable, Sendable {
    public var id: String { username }
    public let username: String
    public let email: String?
    public let adminRole: Bool?
    public let downloadRole: Bool?
    public let shareRole: Bool?
    public let jukeboxRole: Bool?
}

public struct NavidromeMetadata: Decodable, Sendable {
    public let biography: String?
    public let notes: String?
    public let musicBrainzId: String?
    public let lastFmUrl: URL?
    public let similarArtist: [MusicArtist]?
}

public struct NavidromeBookmark: Decodable, Identifiable, Sendable {
    public var id: String { entry.id }
    public let entry: NavidromeTrack
    public let position: Int64
    public let comment: String?
}

public struct NavidromeQueue: Decodable, Sendable {
    public let entry: [NavidromeTrack]?
    public let current: String?
    public let currentIndex: Int?
    public let position: Int64?
    public let changedBy: String?

    public var selectedIndex: Int {
        if let currentIndex, entry?.indices.contains(currentIndex) == true { return currentIndex }
        return entry?.firstIndex { $0.id == current } ?? 0
    }
}

public struct NavidromeActivity: Decodable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let username: String?
    public let playerName: String?
    public let state: String?
    public let positionMs: Int64?
}

public struct NavidromeDirectoryEntry: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let isDir: Bool?
    public let coverArt: String?
}

extension NavidromeClient {
    public func musicFolders() async throws -> [NavidromeFolder] {
        struct Payload: Decodable {
            struct Folders: Decodable { let musicFolder: [NavidromeFolder]? }
            let musicFolders: Folders?
        }
        return try await subsonic(Payload.self, "getMusicFolders").musicFolders?.musicFolder ?? []
    }

    public func user() async throws -> NavidromeUser {
        struct Payload: Decodable { let user: NavidromeUser }
        return try await subsonic(Payload.self, "getUser", [arg("username", username)]).user
    }

    public func users() async throws -> [NavidromeUser] {
        struct Payload: Decodable {
            struct Users: Decodable { let user: [NavidromeUser]? }
            let users: Users?
        }
        return try await subsonic(Payload.self, "getUsers").users?.user ?? []
    }

    public func song(_ id: String) async throws -> NavidromeTrack {
        struct Payload: Decodable { let song: NavidromeTrack }
        return try await subsonic(Payload.self, "getSong", [Self.id(id)]).song
    }

    public func directoryArtists(folder: Int? = nil, changedSince: Int64? = nil) async throws -> [MusicArtist] {
        struct Payload: Decodable {
            struct Indexes: Decodable {
                struct Index: Decodable { let artist: [MusicArtist]? }
                let index: [Index]?
            }
            let indexes: Indexes?
        }
        return try await subsonic(Payload.self, "getIndexes", optional("musicFolderId", folder) + optional("ifModifiedSince", changedSince))
            .indexes?.index?.flatMap { $0.artist ?? [] } ?? []
    }

    public func directory(_ id: String) async throws -> [NavidromeDirectoryEntry] {
        struct Payload: Decodable {
            struct Directory: Decodable { let child: [NavidromeDirectoryEntry]? }
            let directory: Directory
        }
        return try await subsonic(Payload.self, "getMusicDirectory", [Self.id(id)]).directory.child ?? []
    }

    public func albumInfo(_ id: String, legacy: Bool = false) async throws -> NavidromeMetadata? {
        struct Payload: Decodable { let albumInfo: NavidromeMetadata? }
        return try await subsonic(Payload.self, legacy ? "getAlbumInfo" : "getAlbumInfo2", [Self.id(id)]).albumInfo
    }

    public func artistInfo(_ id: String, limit: Int = 12, includeUnavailable: Bool = false,
                           legacy: Bool = false) async throws -> NavidromeMetadata? {
        struct Payload: Decodable { let artistInfo: NavidromeMetadata?; let artistInfo2: NavidromeMetadata? }
        let payload = try await subsonic(Payload.self, legacy ? "getArtistInfo" : "getArtistInfo2",
                                         [Self.id(id), arg("count", limit), arg("includeNotPresent", includeUnavailable)])
        return payload.artistInfo2 ?? payload.artistInfo
    }

    public func topSongs(artist: String, id: String? = nil, limit: Int = 20) async throws -> [NavidromeTrack] {
        try await subsonic(SongGroups.self, "getTopSongs", [arg("artist", artist), arg("count", limit)] + optional("id", id)).topSongs?.song ?? []
    }

    public func similarSongs(_ id: String, limit: Int = 20, legacy: Bool = false) async throws -> [NavidromeTrack] {
        let payload = try await subsonic(SongGroups.self, legacy ? "getSimilarSongs" : "getSimilarSongs2", [Self.id(id), arg("count", limit)])
        return (payload.similarSongs2 ?? payload.similarSongs)?.song ?? []
    }

    public func randomSongs(limit: Int = 30, genre: String? = nil, fromYear: Int? = nil, toYear: Int? = nil,
                            folder: Int? = nil) async throws -> [NavidromeTrack] {
        try await subsonic(SongGroups.self, "getRandomSongs", [arg("size", limit)] + optional("genre", genre)
                            + optional("fromYear", fromYear) + optional("toYear", toYear) + optional("musicFolderId", folder)).randomSongs?.song ?? []
    }

    public func sonicMatches(from id: String, to destination: String? = nil, limit: Int = 20) async throws -> [NavidromeTrack] {
        struct Payload: Decodable {
            struct Match: Decodable { let entry: NavidromeTrack }
            let sonicMatches: [Match]?
        }
        let params = (destination.map { [arg("startSongId", id), arg("endSongId", $0)] } ?? [Self.id(id)]) + [arg("count", limit)]
        return try await subsonic(Payload.self, destination == nil ? "getSonicSimilarTracks" : "findSonicPath", params)
            .sonicMatches?.map(\.entry) ?? []
    }

    public func legacyAlbums(type: String, limit: Int = 50, offset: Int = 0) async throws -> [NavidromeDirectoryEntry] {
        struct Payload: Decodable {
            struct Albums: Decodable { let album: [NavidromeDirectoryEntry]? }
            let albumList: Albums?
        }
        return try await subsonic(Payload.self, "getAlbumList", [arg("type", type), arg("size", limit), arg("offset", offset)])
            .albumList?.album ?? []
    }

    public func legacyFavorites() async throws -> MusicSearchResults {
        struct Payload: Decodable { let starred: MusicSearchResults? }
        return try await subsonic(Payload.self, "getStarred").starred ?? MusicSearchResults()
    }

    public func legacySearch(_ query: String, limit: Int = 30) async throws -> MusicSearchResults {
        struct Payload: Decodable { let searchResult2: MusicSearchResults? }
        return try await subsonic(Payload.self, "search2", [arg("query", query), arg("songCount", limit),
                                   arg("albumCount", limit), arg("artistCount", limit)]).searchResult2 ?? MusicSearchResults()
    }

    public enum FavoriteKind: String, Sendable { case song = "id", album = "albumId", artist = "artistId" }

    public func setFavorite(_ enabled: Bool, id: String, kind: FavoriteKind = .song) async throws {
        try await write(enabled ? "star" : "unstar", [arg(kind.rawValue, id)])
    }

    public func setRating(_ rating: Int, id: String) async throws {
        try await write("setRating", [Self.id(id), arg("rating", min(5, max(0, rating)))])
    }

    public func createPlaylist(name: String, songIDs: [String] = [], replacing: String? = nil, form: Bool) async throws -> MusicPlaylist? {
        struct Payload: Decodable { let playlist: MusicPlaylist? }
        return try await subsonic(Payload.self, "createPlaylist", [arg("name", name)] + optional("playlistId", replacing)
                                  + songIDs.map { arg("songId", $0) }, form: form).playlist
    }

    public func updatePlaylist(_ id: String, name: String? = nil, comment: String? = nil, isPublic: Bool? = nil,
                               adding: [String] = [], removing: [Int] = [], form: Bool) async throws {
        try await write("updatePlaylist", [arg("playlistId", id)] + optional("name", name) + optional("comment", comment)
                        + optional("public", isPublic) + adding.map { arg("songIdToAdd", $0) }
                        + removing.map { arg("songIndexToRemove", $0) }, form: form)
    }

    public func deletePlaylist(_ id: String) async throws { try await write("deletePlaylist", [Self.id(id)]) }

    public func bookmarks() async throws -> [NavidromeBookmark] {
        struct Payload: Decodable {
            struct Bookmarks: Decodable { let bookmark: [NavidromeBookmark]? }
            let bookmarks: Bookmarks?
        }
        return try await subsonic(Payload.self, "getBookmarks").bookmarks?.bookmark ?? []
    }

    public func saveBookmark(_ id: String, position: Double, comment: String? = nil) async throws {
        try await write("createBookmark", [Self.id(id), arg("position", milliseconds(position))] + optional("comment", comment))
    }

    public func deleteBookmark(_ id: String) async throws { try await write("deleteBookmark", [Self.id(id)]) }

    public func savedQueue(indexed: Bool) async throws -> NavidromeQueue? {
        struct Payload: Decodable { let playQueue: NavidromeQueue?; let playQueueByIndex: NavidromeQueue? }
        let response = try await subsonic(Payload.self, indexed ? "getPlayQueueByIndex" : "getPlayQueue")
        return indexed ? response.playQueueByIndex : response.playQueue
    }

    public func saveQueue(ids: [String], currentIndex: Int, position: Double, indexed: Bool, form: Bool) async throws {
        let selected = ids.indices.contains(currentIndex) ? currentIndex : 0
        try await write(indexed ? "savePlayQueueByIndex" : "savePlayQueue",
                        ids.map(Self.id) + (indexed ? [arg("currentIndex", selected)] : optional("current", ids.first.map { _ in ids[selected] }))
                        + [arg("position", milliseconds(position))], form: form)
    }

    public func nowPlaying() async throws -> [NavidromeActivity] {
        struct Payload: Decodable {
            struct Now: Decodable { let entry: [NavidromeActivity]? }
            let nowPlaying: Now?
        }
        return try await subsonic(Payload.self, "getNowPlaying").nowPlaying?.entry ?? []
    }

    func write(_ endpoint: String, _ params: [URLQueryItem], form: Bool = false) async throws {
        struct Ack: Decodable {}
        _ = try await subsonic(Ack.self, endpoint, params, form: form)
    }
}

private struct SongGroups: Decodable {
    struct Songs: Decodable { let song: [NavidromeTrack]? }
    let topSongs: Songs?
    let similarSongs: Songs?
    let similarSongs2: Songs?
    let randomSongs: Songs?
}

func arg(_ key: String, _ value: some CustomStringConvertible) -> URLQueryItem { .init(name: key, value: value.description) }

func optional<T: CustomStringConvertible>(_ key: String, _ value: T?) -> [URLQueryItem] {
    value.map { [arg(key, $0)] } ?? []
}

func milliseconds(_ seconds: Double) -> Int64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int64(min(seconds * 1000, Double(Int64.max / 2)))
}
