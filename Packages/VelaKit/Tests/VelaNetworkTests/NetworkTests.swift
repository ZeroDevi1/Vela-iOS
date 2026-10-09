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

    /// 「服务器转码为 4K」：宽度上限编码为必需的 CodecProfile 条件，服务器据此不直放并缩放转码。
    @Test func maxVideoWidthBecomesRequiredCodecCondition() throws {
        var caps = PlaybackCapabilities(supportsAV1: false, supportsDolbyVision: true, supportsHDR10: true)
        let unlimited = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceProfile.avFoundation(caps))) as? [String: Any]
        #expect((unlimited?["CodecProfiles"] as? [Any])?.isEmpty == true)

        caps.maxVideoWidth = 3840
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceProfile.avFoundation(caps))) as? [String: Any]
        let profile = try #require((object?["CodecProfiles"] as? [[String: Any]])?.first)
        let condition = try #require((profile["Conditions"] as? [[String: Any]])?.first)
        #expect(profile["Type"] as? String == "Video")
        #expect(condition["Property"] as? String == "Width")
        #expect(condition["Condition"] as? String == "LessThanEqual")
        #expect(condition["Value"] as? String == "3840")
        #expect(condition["IsRequired"] as? Bool == true)
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

struct MediaSelectionTests {
    private func source(_ id: String, width: Int, height: Int, bitrate: Int, range: String = "SDR", audio: [String] = []) throws -> MediaSourceInfo {
        let audioJSON = audio.enumerated().map { #"{"Type":"Audio","Index":\#($0.offset + 1),"Language":"\#($0.element)"}"# }
        let json = #"{"Id":"\#(id)","Bitrate":\#(bitrate),"MediaStreams":[{"Type":"Video","Index":0,"Width":\#(width),"Height":\#(height),"VideoRangeType":"\#(range)"}\#(audioJSON.isEmpty ? "" : "," + audioJSON.joined(separator: ","))]}"#
        return try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8))
    }

    @Test func languageCodesAreNormalized() {
        #expect(MediaSelection.normalizedLanguage("zho") == "chi")
        #expect(MediaSelection.normalizedLanguage("zh-Hans") == "chi")
        #expect(MediaSelection.normalizedLanguage("en") == "eng")
        #expect(MediaSelection.normalizedLanguage("") == nil)
    }

    @Test func matchesFirstStreamInPreferredLanguage() throws {
        let streams = try source("a", width: 1920, height: 1080, bitrate: 1, audio: ["eng", "zho", "chi"]).audioStreams
        #expect(MediaSelection.firstStream(matching: "chi", in: streams)?.index == 2)
        #expect(MediaSelection.firstStream(matching: "", in: streams) == nil)
        #expect(MediaSelection.firstStream(matching: "jpn", in: streams) == nil)
    }

    @Test func versionPreference() throws {
        let hd = try source("hd", width: 1920, height: 1080, bitrate: 8_000_000)
        let uhd = try source("uhd", width: 3840, height: 2160, bitrate: 40_000_000)
        #expect(MediaSelection.preferredSource([hd, uhd], by: .serverDefault)?.id == "hd")
        #expect(MediaSelection.preferredSource([hd, uhd], by: .highestQuality)?.id == "uhd")
        #expect(MediaSelection.preferredSource([uhd, hd], by: .highestBitrate)?.id == "uhd")
    }

    @Test func versionPreferenceByTierAndRange() throws {
        let sd = try source("720", width: 1280, height: 720, bitrate: 3_000_000)
        let hd = try source("1080", width: 1920, height: 800, bitrate: 8_000_000)
        let uhd = try source("4k", width: 3840, height: 2160, bitrate: 40_000_000)
        let dv = try source("dv", width: 1920, height: 1080, bitrate: 6_000_000, range: "DOVIWithHDR10")
        #expect(MediaSelection.preferredSource([uhd, hd, sd], by: .fullHD1080)?.id == "1080")
        #expect(MediaSelection.preferredSource([uhd, hd, sd], by: .hd720)?.id == "720")
        #expect(MediaSelection.preferredSource([sd, hd], by: .uhd4K)?.id == "1080")
        // 没有不超过目标的版本时取最小的一个。
        #expect(MediaSelection.preferredSource([uhd, hd], by: .hd720)?.id == "1080")
        #expect(MediaSelection.preferredSource([uhd, dv], by: .bestDynamicRange)?.id == "dv")
        #expect(MediaVersionPreference.stored("lowestBitrate") == .hd720)
        #expect(MediaVersionPreference.stored("highestQuality") == .highestQuality)
    }
}

struct RemoteSubtitleTests {
    @Test func decodesServerSearchResult() throws {
        let json = #"[{"Id":"opensubtitles_123","ProviderName":"Open Subtitles","Name":"Movie.2024.1080p","Format":"srt","DownloadCount":42,"IsHashMatch":true,"ThreeLetterISOLanguageName":"chi"}]"#
        let results = try JSONDecoder().decode([RemoteSubtitle].self, from: Data(json.utf8))
        #expect(results.first?.id == "opensubtitles_123")
        #expect(results.first?.isHashMatch == true)
        #expect(results.first?.language == "chi")
    }
}

struct SubtitleDecodingTests {
    /// 服务器原样透传 GBK 编码的 SRT 时按 GB18030 解码，而不是 Latin-1 乱码。
    @Test func decodesGBKSubtitle() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try #require("沈家灭门".data(using: encoding))
        #expect(MediaServerClient.decodeSubtitleText(data) == "沈家灭门")
        #expect(MediaServerClient.decodeSubtitleText(Data("字幕".utf8)) == "字幕")
    }

    /// 原盘识别：Jellyfin 的 `VideoType` / `IsoType`，字段缺失时按容器与路径。
    @Test func detectsDiscImages() throws {
        func source(_ fields: String) throws -> MediaSourceInfo {
            try JSONDecoder().decode(MediaSourceInfo.self, from: Data("{\"Id\":\"a\",\(fields)}".utf8))
        }
        #expect(try source(#""VideoType":"BluRay","Container":"m2ts""#).isDiscImage)
        #expect(try source(#""IsoType":"Dvd""#).isDiscImage)
        #expect(try source(#""Container":"iso""#).isDiscImage)
        #expect(try source(#""Path":"D:\\Movies\\Film\\BDMV""#).isDiscImage)
        #expect(try source(#""Path":"/media/Film/BDMV/index.bdmv""#).isDiscImage)
        #expect(try source(#""Path":"/media/Film.ISO""#).isDiscImage)
        #expect(try !source(#""VideoType":"VideoFile","Container":"mkv","Path":"/media/Film.mkv""#).isDiscImage)
    }

    /// 杜比视界 Profile（Jellyfin `DvProfile`、Emby `ExtendedVideoSubType`）与全景声音轨识别。
    @Test func parsesDolbyVisionProfileAndAtmos() throws {
        func stream(_ fields: String) throws -> MediaStreamInfo {
            try JSONDecoder().decode(MediaStreamInfo.self, from: Data("{\"Index\":0,\"Type\":\"Video\",\(fields)}".utf8))
        }
        #expect(try stream(#""DvProfile":8"#).dolbyVisionProfile == 8)
        #expect(try stream(#""ExtendedVideoSubType":"DoviProfile81""#).dolbyVisionProfile == 8)
        #expect(try stream(#""ExtendedVideoSubType":"DoviProfile76""#).dolbyVisionProfile == 7)
        #expect(try stream(#""ExtendedVideoSubType":"DoviProfile50""#).dolbyVisionProfile == 5)
        #expect(try stream(#""ExtendedVideoSubType":"None""#).dolbyVisionProfile == nil)
        #expect(try stream(#""Profile":"Dolby Digital Plus + Dolby Atmos""#).isDolbyAtmos)
        #expect(try stream(#""DisplayTitle":"English EAC3 5.1 Atmos""#).isDolbyAtmos)
        #expect(try !stream(#""Profile":"Dolby Digital Plus""#).isDolbyAtmos)
    }
}
