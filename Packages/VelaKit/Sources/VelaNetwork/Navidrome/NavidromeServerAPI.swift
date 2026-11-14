import Foundation

public struct NavidromeScan: Decodable, Sendable {
    public let scanning: Bool
    public let count: Int
    public let folderCount: Int?
    public let lastScan: String?
    public let scanType: String?
    public let error: String?
}

public struct NavidromeShare: Decodable, Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let description: String?
    public let username: String
    public let expires: String?
    public let visitCount: Int?
}

public struct NavidromeRadio: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let streamUrl: String
    public let homePageUrl: String?
    public let coverArt: String?
}

public struct NavidromeJukebox: Decodable, Sendable {
    public let currentIndex: Int
    public let playing: Bool
    public let gain: Double
    public let position: Int?
    public let entry: [NavidromeTrack]?
}

public struct NavidromeTranscodeDecision: Decodable, Sendable {
    public let canDirectPlay: Bool
    public let canTranscode: Bool
    public let transcodeParams: String?
}

extension NavidromeClient {
    public func licenseValid() async throws -> Bool {
        struct Payload: Decodable {
            struct License: Decodable { let valid: Bool }
            let license: License
        }
        return try await subsonic(Payload.self, "getLicense").license.valid
    }

    public func tokenUsername() async throws -> String {
        struct Payload: Decodable {
            struct Token: Decodable { let username: String }
            let tokenInfo: Token
        }
        return try await subsonic(Payload.self, "tokenInfo").tokenInfo.username
    }

    public func scanStatus() async throws -> NavidromeScan { try await scan("getScanStatus", []) }

    public func startScan(full: Bool, targets: [String] = []) async throws -> NavidromeScan {
        try await scan("startScan", [arg("fullScan", full)] + targets.map { arg("target", $0) })
    }

    private func scan(_ endpoint: String, _ params: [URLQueryItem]) async throws -> NavidromeScan {
        struct Payload: Decodable { let scanStatus: NavidromeScan }
        return try await subsonic(Payload.self, endpoint, params).scanStatus
    }

    public func avatar() async throws -> Data {
        let (bytes, response) = try await fetch(endpoint("getAvatar", [arg("username", username)]))
        guard response.mimeType?.hasPrefix("image/") == true else { throw NavidromeError.invalidResponse }
        return bytes
    }

    public func shares() async throws -> [NavidromeShare] {
        try await subsonic(SharePayload.self, "getShares").shares?.share ?? []
    }

    public func createShare(ids: [String], description: String, expires: Date?, downloadable: Bool) async throws -> [NavidromeShare] {
        try await subsonic(SharePayload.self, "createShare", ids.map(Self.id) + [
            arg("description", description), arg("downloadable", downloadable)
        ] + optional("expires", expires.map { milliseconds($0.timeIntervalSince1970) })).shares?.share ?? []
    }

    public func updateShare(_ id: String, description: String, expires: Date?, downloadable: Bool?) async throws {
        try await write("updateShare", [Self.id(id), arg("description", description), arg("expires", expires.map { milliseconds($0.timeIntervalSince1970) } ?? 0)]
                        + optional("downloadable", downloadable))
    }

    public func deleteShare(_ id: String) async throws { try await write("deleteShare", [Self.id(id)]) }

    public func radios() async throws -> [NavidromeRadio] {
        struct Payload: Decodable {
            struct Stations: Decodable { let internetRadioStation: [NavidromeRadio]? }
            let internetRadioStations: Stations?
        }
        return try await subsonic(Payload.self, "getInternetRadioStations").internetRadioStations?.internetRadioStation ?? []
    }

    public func saveRadio(id: String? = nil, name: String, stream: URL, homepage: URL?) async throws {
        try await write(id == nil ? "createInternetRadioStation" : "updateInternetRadioStation",
                        optional("id", id) + [arg("name", name), arg("streamUrl", stream.absoluteString), arg("homepageUrl", homepage?.absoluteString ?? "")])
    }

    public func deleteRadio(_ id: String) async throws { try await write("deleteInternetRadioStation", [Self.id(id)]) }

    public enum JukeboxAction: Sendable {
        case get, status, start, stop, clear, shuffle
        case set([String]), add([String]), skip(index: Int, offset: Int = 0), remove(Int), gain(Double)

        var name: String {
            switch self {
            case .get: "get"
            case .status: "status"
            case .start: "start"
            case .stop: "stop"
            case .clear: "clear"
            case .shuffle: "shuffle"
            case .set: "set"
            case .add: "add"
            case .skip: "skip"
            case .remove: "remove"
            case .gain: "setGain"
            }
        }

        var parameters: [URLQueryItem] {
            switch self {
            case .set(let ids), .add(let ids): ids.map(NavidromeClient.id)
            case .skip(let index, let offset): [arg("index", index), arg("offset", offset)]
            case .remove(let index): [arg("index", index)]
            case .gain(let gain): [arg("gain", gain)]
            default: []
            }
        }
    }

    public func jukebox(_ action: JukeboxAction, form: Bool = false) async throws -> NavidromeJukebox {
        struct Payload: Decodable { let jukeboxStatus: NavidromeJukebox?; let jukeboxPlaylist: NavidromeJukebox? }
        let response = try await subsonic(Payload.self, "jukeboxControl", [arg("action", action.name)] + action.parameters, form: form)
        guard let state = response.jukeboxPlaylist ?? response.jukeboxStatus else { throw NavidromeError.invalidResponse }
        return state
    }

    public func transcodeDecision(id: String, compatible: Bool) async throws -> NavidromeTranscodeDecision {
        struct Payload: Decodable { let transcodeDecision: NavidromeTranscodeDecision }
        let direct: [[String: Any]] = compatible ? [] : [
            ["containers": ["flac", "mp3", "aac", "m4a", "mp4", "alac", "wav", "aiff"], "protocols": ["http"]]
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "name": "Vela", "maxTranscodingAudioBitrate": 192_000, "directPlayProfiles": direct,
            "transcodingProfiles": [["container": "mp3", "audioCodec": "mp3", "protocol": "http", "maxAudioChannels": 2]]
        ])
        return try await subsonic(Payload.self, "getTranscodeDecision",
                                  [arg("mediaId", id), arg("mediaType", "song")], jsonBody: body).transcodeDecision
    }

    public func transcodeURL(id: String, token: String, offset: Int = 0) throws -> URL {
        try endpoint("getTranscodeStream", [
            arg("mediaId", id), arg("mediaType", "song"), arg("transcodeParams", token), arg("offset", offset)
        ])
    }

    public func download(id: String) async throws -> (file: URL, suggestedName: String?) {
        let url = try endpoint("download", [Self.id(id), arg("format", "raw")])
        return try await downloadResource(url)
    }
}

private struct SharePayload: Decodable {
    struct Shares: Decodable { let share: [NavidromeShare]? }
    let shares: Shares?
}
