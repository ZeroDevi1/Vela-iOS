import Foundation
import Testing
import VelaCore
@testable import VelaNetwork

struct ServerDiscoveryTests {
    @Test func wanAddressTriesHTTPSFirstAndAddsEmbyVariant() {
        let urls = ServerDiscovery.candidates(for: "media.example.com/").map(\.absoluteString)
        #expect(urls == [
            "https://media.example.com",
            "https://media.example.com/emby",
            "http://media.example.com",
            "http://media.example.com/emby"
        ])
    }

    @Test func lanAddressTriesHTTPFirst() {
        let urls = ServerDiscovery.candidates(for: "192.168.1.5:8096").map(\.absoluteString)
        #expect(urls.first == "http://192.168.1.5:8096")
    }

    @Test func explicitSchemeAndEmbySuffixAreKept() {
        let urls = ServerDiscovery.candidates(for: "https://host/emby").map(\.absoluteString)
        #expect(urls == ["https://host/emby"])
    }

    @Test func detectsKind() throws {
        let json = #"{"ServerName":"x","ProductName":"Emby Server","Version":"4.8.0","Id":"1"}"#
        let info = try JSONDecoder().decode(PublicSystemInfo.self, from: Data(json.utf8))
        #expect(ServerDiscovery.detectKind(info: info, applicationHeader: nil) == .emby)
        #expect(ServerDiscovery.detectKind(info: info, applicationHeader: "Jellyfin Server/10.10") == .jellyfin)
    }
}

struct AuthorizationHeaderTests {
    private let identity = ClientIdentity(deviceName: "iPhone", deviceID: "dev-1", version: "1.0")

    @Test func jellyfinSchemeWithToken() {
        let header = AuthorizationHeader(kind: .jellyfin, identity: identity, accessToken: "tok")
        #expect(header.value == #"MediaBrowser Client="Vela", Device="iPhone", DeviceId="dev-1", Version="1.0", Token="tok""#)
        #expect(header.headers["X-Emby-Token"] == "tok")
    }

    @Test func embySchemeWithoutToken() {
        let header = AuthorizationHeader(kind: .emby, identity: identity)
        #expect(header.value.hasPrefix("Emby "))
        #expect(!header.value.contains("Token="))
        #expect(header.headers["X-Emby-Token"] == nil)
    }
}

struct HTTPClientTests {
    @Test func keepsBasePathPrefix() throws {
        let url = try HTTPClient.makeURL(
            baseURL: URL(string: "https://host/jellyfin/")!,
            path: "/Users/1/Views",
            query: [.init(name: "Limit", value: "5")]
        )
        #expect(url.absoluteString == "https://host/jellyfin/Users/1/Views?Limit=5")
    }

    @Test func parsesServerDatesWithSevenFractionDigits() {
        #expect(ServerDate.parse("2024-05-01T12:34:56.1234567Z") != nil)
        #expect(ServerDate.parse("2024-05-01T12:34:56Z") != nil)
    }

    @Test func absoluteTranscodeURLAddsTokenOnce() throws {
        let client = MediaServerClient(
            serverID: "s", baseURL: URL(string: "https://host/emby")!, kind: .emby,
            userID: "u", accessToken: "tok", identity: ClientIdentity(deviceName: "d", deviceID: "id", version: "1")
        )
        let url = try client.absoluteURL(forServerRelative: "/videos/1/master.m3u8?MediaSourceId=1")
        #expect(url.absoluteString == "https://host/emby/videos/1/master.m3u8?MediaSourceId=1&api_key=tok")
        let existing = try client.absoluteURL(forServerRelative: "/videos/1/master.m3u8?api_key=old")
        #expect(existing.absoluteString == "https://host/emby/videos/1/master.m3u8?api_key=old")
    }
}

struct MappingTests {
    @Test func mapsEpisodeAndLowercasesProviderKeys() throws {
        let json = #"""
        {"Id":"e1","Name":"Pilot","Type":"Episode","IndexNumber":2,"ParentIndexNumber":1,
         "RunTimeTicks":36000000000,"ProviderIds":{"Tmdb":"42"},
         "UserData":{"PlaybackPositionTicks":9000000000,"Played":false}}
        """#
        let dto = try JSONDecoder().decode(BaseItemDTO.self, from: Data(json.utf8))
        let item = dto.toMediaItem(serverID: "s")
        #expect(item.kind == .episode)
        #expect(item.episodeLabel == "S01E02")
        #expect(item.providerIDs["tmdb"] == "42")
        #expect(item.playedFraction == 0.25)
    }
}

struct LoginBodyTests {
    /// 回归：Emby 收到明文 `Password`（旧 SHA1 字段）会判定密码错误。
    @Test func sendsOnlyUsernameAndPw() throws {
        let data = try JSONEncoder().encode(AuthenticateByNameBody(username: "u", password: "p"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object == ["Username": "u", "Pw": "p"])
    }
}

struct PlaybackBodyTests {
    @Test func playbackInfoDefaultsSubtitleToDisabled() throws {
        let body = PlaybackInfoBody(
            userID: "u", maxStreamingBitrate: 1, startTimeTicks: 0, mediaSourceID: nil,
            audioStreamIndex: nil, subtitleStreamIndex: nil,
            deviceProfile: .avFoundation(PlaybackCapabilities(supportsAV1: false, supportsDolbyVision: true, supportsHDR10: true))
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(object?["SubtitleStreamIndex"] as? Int == -1)
        #expect(object?["AudioStreamIndex"] == nil)
    }

    @Test func reportBodyUsesTicks() throws {
        let body = PlaybackReportBody(
            itemID: "i", mediaSourceID: "m", playSessionID: "p", positionTicks: Ticks.ticks(12.5),
            isPaused: true, playMethod: "DirectPlay", audioStreamIndex: 1, subtitleStreamIndex: nil, eventName: "pause"
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(object?["PositionTicks"] as? Int == 125_000_000)
        #expect(object?["EventName"] as? String == "pause")
        #expect(object?["SubtitleStreamIndex"] == nil)
    }
}

struct DetailsDecodingTests {
    /// 回归：Emby 的 Studios[].Id 为数字。
    @Test func acceptsNumericStudioIDs() throws {
        let json = #"{"Id":"1","Name":"柯南","Type":"Series","Studios":[{"Name":"TMS","Id":12}],"People":[{"Id":"p","Name":"高山南","Role":"Conan","Type":"Actor"}]}"#
        let details = try JSONDecoder.server.decode(BaseItemDTO.self, from: Data(json.utf8)).toDetails(serverID: "s")
        #expect(details.studios == ["TMS"])
        #expect(details.people.first?.role == "Conan")
    }
}
