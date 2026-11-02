import Foundation
import Testing
import VelaCore
@testable import VelaNetwork

struct DetailStillsTests {
    private var client: MediaServerClient {
        MediaServerClient(serverID: "server", baseURL: URL(string: "https://example.test/emby")!,
                          kind: .emby, userID: "user", accessToken: "",
                          identity: ClientIdentity(deviceName: "test", deviceID: "test", version: "1"))
    }

    @Test func decodesBothImageTypesPreservingIndicesAndOrder() throws {
        let json = #"{"Id":"movie","Name":"Movie","Type":"Movie","BackdropImageTags":["b0"," ","b2"],"ScreenshotImageTags":["","s1"]}"#
        let detail = try JSONDecoder().decode(BaseItemDTO.self, from: Data(json.utf8)).toDetails(serverID: "server")
        let images = client.stillImages(for: detail.item, screenshotTags: detail.screenshotImageTags)
        #expect(images.map(\.id) == ["movie/Backdrop/0", "movie/Backdrop/2", "movie/Screenshot/1"])
        #expect(images.last?.thumbnailURL.path == "/emby/Items/movie/Images/Screenshot/1")
        let thumbnail = URLComponents(url: images[0].thumbnailURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(thumbnail.contains(.init(name: "fillWidth", value: "560")))
        #expect(thumbnail.contains(.init(name: "fillHeight", value: "315")))
        #expect(thumbnail.contains(.init(name: "quality", value: "80")))
        #expect(thumbnail.contains(.init(name: "tag", value: "b0")))
        let preview = URLComponents(url: images[0].previewURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(preview.contains(.init(name: "maxWidth", value: "1920")))
        #expect(preview.contains(.init(name: "quality", value: "95")))
        #expect(!preview.contains { $0.name == "maxHeight" })
    }

    @Test func absentAndSingleScreenshotNeedNoBackdropOrParentFallback() throws {
        let json = #"{"Id":"movie","Name":"Movie","Type":"Movie","ParentBackdropItemId":"parent","ParentBackdropImageTags":["parent-tag"]}"#
        let detail = try JSONDecoder().decode(BaseItemDTO.self, from: Data(json.utf8)).toDetails(serverID: "server")
        #expect(detail.screenshotImageTags.isEmpty)
        #expect(client.stillImages(for: detail.item).isEmpty)
        let images = client.stillImages(for: detail.item, screenshotTags: ["single"])
        #expect(images.count == 1)
        #expect(images[0].id == "movie/Screenshot/0")
    }
}
