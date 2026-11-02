import Foundation
import Synchronization
import Testing
import VelaCore
import VelaNetwork
@testable import VelaFeatures

private final class DelayedAlternateProtocol: URLProtocol, @unchecked Sendable {
    static let failAlternate = Mutex(false)
    static let events = Mutex<[(String, Date)]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.events.withLock { $0.append((path, Date())) }
        let alternate = path.hasSuffix("/alternate")
        let failing = alternate && Self.failAlternate.withLock { $0 }
        let body: String
        if alternate {
            body = #"{"Id":"alternate","Name":"Alternate","Type":"Movie","MediaSources":[{"Id":"alternate-source"}]}"#
        } else if path.hasSuffix("/main") {
            body = #"{"Id":"main","Name":"Fixture","Type":"Movie","MediaSources":[{"Id":"source"}]}"#
        } else {
            body = path.hasSuffix("/Similar") ? #"{"Items":[{"Id":"similar","Name":"Similar","Type":"Movie"}],"TotalRecordCount":1}"# : "[]"
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (alternate ? 0.8 : 0)) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failing ? 500 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct DetailLoadingTests {
    @MainActor @Test func slowMergedVersionDoesNotBlockOtherSections() async {
        DelayedAlternateProtocol.failAlternate.withLock { $0 = false }
        DelayedAlternateProtocol.events.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAlternateProtocol.self]
        let client = MediaServerClient(serverID: "fixture", baseURL: URL(string: "https://fixture.invalid")!, kind: .jellyfin,
                                       userID: "user", accessToken: "", identity: ClientIdentity(deviceName: "test", deviceID: "test", version: "1"),
                                       http: HTTPClient(session: URLSession(configuration: configuration)))
        var item = MediaItem(id: "main", serverID: "fixture", name: "Fixture", kind: .movie)
        item.mergedItemIDs = ["alternate"]
        let model = DetailModel(item: item)
        await model.load(client: client)
        let events = DelayedAlternateProtocol.events.withLock { $0 }
        let alternate = events.first { $0.0.hasSuffix("/alternate") }
        let similar = events.first { $0.0.hasSuffix("/Similar") }
        #expect(alternate != nil)
        #expect(similar != nil)
        if let alternate, let similar {
            let interval = similar.1.timeIntervalSince(alternate.1)
            print("Similar request relative to slow alternate start: \(interval)s; injected alternate delay: 0.8s")
            #expect(interval < 0.6)
        }
        #expect(model.selectedSourceID == "source")
        #expect(model.alternates.count == 1)
        #expect(model.similar.map(\.id) == ["similar"])

        // 回到页面刷新时，已选择的合并版本可能失败/消失，默认源与其它分区仍可用。
        model.selectedSourceID = "alternate-source"
        model.resetSelections()
        DelayedAlternateProtocol.failAlternate.withLock { $0 = true }
        defer { DelayedAlternateProtocol.failAlternate.withLock { $0 = false } }
        await model.load(client: client)
        #expect(model.alternates.isEmpty)
        #expect(model.selectedSourceID == "source")
        #expect(model.playbackItem.id == "main")
        #expect(model.similar.map(\.id) == ["similar"])
    }
}
