import Foundation
import Testing
import VelaCore
@testable import VelaNetwork

/// 社区片头 / 片尾标记：解析两个来源，只补充服务器没有的类型。
struct CommunitySegmentsTests {
    @Test func parsesTheIntroDB() throws {
        let json = #"{"tmdb_id":1,"intro":[{"start_ms":30000,"end_ms":90000}],"recap":[],"credits":[{"start_ms":2500000}],"preview":[{"start_ms":10,"end_ms":5}]}"#
        let segments = try CommunitySegmentsClient.parseTheIntroDB(Data(json.utf8))
        #expect(segments == [
            PlaybackSegment(kind: .intro, start: 30, end: 90),
            PlaybackSegment(kind: .outro, start: 2500, end: nil),
        ])
    }

    @Test func parsesIntroDBRequiresBothEnds() throws {
        #expect(try CommunitySegmentsClient.parseIntroDB(Data(#"{"intro":{"start_ms":1000,"end_ms":61000}}"#.utf8))
            == PlaybackSegment(kind: .intro, start: 1, end: 61))
        #expect(try CommunitySegmentsClient.parseIntroDB(Data(#"{"intro":{"start_ms":1000}}"#.utf8)) == nil)
    }

    @Test func serverSegmentsWin() {
        let server = [PlaybackSegment(kind: .intro, start: 10, end: 70)]
        let community = [PlaybackSegment(kind: .intro, start: 0, end: 60), PlaybackSegment(kind: .outro, start: 2400, end: nil)]
        #expect(PlaybackSegment.merging(server: server, community: community) == [
            PlaybackSegment(kind: .intro, start: 10, end: 70), PlaybackSegment(kind: .outro, start: 2400, end: nil),
        ])
    }
}
