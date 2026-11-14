import Foundation

public struct NavidromeLyrics: Decodable, Sendable {
    public struct Line: Decodable, Sendable {
        public let start: Double?
        public let end: Double?
        public let value: String
    }

    public struct CueLine: Decodable, Sendable {
        public struct Cue: Decodable, Sendable {
            public let start: Double
            public let end: Double?
            public let value: String
            public let byteStart: Int?
            public let byteEnd: Int?
        }

        public let index: Int
        public let start: Double?
        public let end: Double?
        public let value: String
        public let agentId: String?
        public let cue: [Cue]?
    }

    public struct Agent: Decodable, Sendable {
        public let id: String
        public let role: String?
        public let name: String?
    }

    public let lang: String?
    public let kind: String?
    public let synced: Bool
    public let offset: Double?
    public let line: [Line]?
    public let cueLine: [CueLine]?
    public let agents: [Agent]?
}

extension NavidromeClient {
    public func lyrics(for track: NavidromeTrack, enhanced: Bool) async throws -> [NavidromeLyrics] {
        do {
            let structured = try await lyricsByID(track.id, enhanced: enhanced)
            if !structured.isEmpty { return structured }
        } catch NavidromeError.unavailable {
        } catch NavidromeError.http(404) {
        } catch NavidromeError.service(70) {
        }
        guard let artist = track.artist, !artist.isEmpty,
              let value = try await plainLyrics(artist: artist, title: track.title),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.init(lang: nil, kind: nil, synced: false, offset: nil,
                      line: value.components(separatedBy: .newlines).map { .init(start: nil, end: nil, value: $0) },
                      cueLine: nil, agents: nil)]
    }

    public func lyricsByID(_ id: String, enhanced: Bool) async throws -> [NavidromeLyrics] {
        struct Payload: Decodable {
            struct List: Decodable { let structuredLyrics: [NavidromeLyrics]? }
            let lyricsList: List?
        }
        return try await subsonic(Payload.self, "getLyricsBySongId",
                                  [Self.id(id), .init(name: "enhanced", value: String(enhanced))]).lyricsList?.structuredLyrics ?? []
    }

    public func plainLyrics(artist: String, title: String) async throws -> String? {
        struct Payload: Decodable {
            struct Lyric: Decodable { let value: String? }
            let lyrics: Lyric?
        }
        return try await subsonic(Payload.self, "getLyrics",
                                  [.init(name: "artist", value: artist), .init(name: "title", value: title)]).lyrics?.value
    }
}
