import Foundation
import Testing
@testable import VelaCore

struct LineRoutingTests {
    @Test(arguments: ["192.168.1.2", "10.0.0.8", "172.16.0.1", "172.31.255.1", "nas.local", "media.lan", "localhost", "::1"])
    func lanHosts(_ host: String) {
        #expect(LineRouting.isLANHost(host))
    }

    @Test(arguments: ["172.15.0.1", "172.32.0.1", "example.com", "8.8.8.8", ""])
    func wanHosts(_ host: String) {
        #expect(!LineRouting.isLANHost(host))
    }

    private let lan = ServerLine(id: "lan", url: URL(string: "http://192.168.1.2:8096")!)
    private let wan = ServerLine(id: "wan", url: URL(string: "https://media.example.com")!)
    private let backup = ServerLine(id: "backup", url: URL(string: "https://backup.example.com")!)

    @Test func prefersLANOnWiFi() {
        let picked = LineRouting.pickPreferredLine(
            lines: [wan, lan], reachableIDs: ["wan", "lan"], access: .lanCapable, currentID: "wan"
        )
        #expect(picked?.id == "lan")
    }

    @Test func keepsCurrentLineWithinPreferredGroup() {
        let picked = LineRouting.pickPreferredLine(
            lines: [wan, backup, lan], reachableIDs: ["wan", "backup"], access: .wan, currentID: "backup"
        )
        #expect(picked?.id == "backup")
    }

    @Test func fallsBackToAnyReachableLine() {
        let picked = LineRouting.pickPreferredLine(
            lines: [wan, lan], reachableIDs: ["wan"], access: .lanCapable, currentID: "lan"
        )
        #expect(picked?.id == "wan")
    }

    @Test func returnsNilWhenNothingReachable() {
        #expect(LineRouting.pickPreferredLine(lines: [wan, lan], reachableIDs: [], access: .wan, currentID: nil) == nil)
    }

    @Test func savedServerDisplayNamePrefersNote() {
        var server = SavedServer(
            serverInstanceID: "abc", serverName: "Home", kind: .jellyfin,
            username: "u", userID: "1", note: "  ", lines: [lan]
        )
        #expect(server.displayName == "Home")
        server.note = "客厅 NAS"
        #expect(server.displayName == "客厅 NAS")
        #expect(server.id == "abc|1")
    }
}

struct SegmentTests {
    @Test func embyMarkersBecomeSegments() {
        let chapters = [
            MediaChapter(name: nil, start: 0, marker: .chapter),
            MediaChapter(name: nil, start: 30, marker: .introStart),
            MediaChapter(name: nil, start: 120, marker: .introEnd),
            MediaChapter(name: nil, start: 1300, marker: .creditsStart)
        ]
        let segments = MediaChapter.segments(from: chapters)
        #expect(segments == [
            PlaybackSegment(kind: .intro, start: 30, end: 120),
            PlaybackSegment(kind: .outro, start: 1300, end: nil)
        ])
    }

    @Test func introWithoutEndIsIgnored() {
        #expect(MediaChapter.segments(from: [MediaChapter(name: nil, start: 30, marker: .introStart)]).isEmpty)
    }

    @Test func openEndedOutroRunsToDuration() {
        let outro = PlaybackSegment(kind: .outro, start: 1300, end: nil)
        #expect(outro.contains(1350, duration: 1400))
        #expect(!outro.contains(1200, duration: 1400))
    }
}

struct LineDecisionTests {
    private let lan = ServerLine(id: "lan", url: URL(string: "http://192.168.1.2:8096")!)
    private let wan = ServerLine(id: "wan", url: URL(string: "https://media.example.com")!)

    @Test func switchesToLANWhenBackOnWiFi() {
        let decision = LineRouting.decide(
            lines: [wan, lan], reachableIDs: ["wan", "lan"], access: .lanCapable,
            currentID: "wan", cooldown: LineCooldown()
        )
        #expect(decision == .switchTo(lan))
    }

    @Test func keepsCurrentWhenAlreadyBest() {
        let decision = LineRouting.decide(
            lines: [wan, lan], reachableIDs: ["wan", "lan"], access: .lanCapable,
            currentID: "lan", cooldown: LineCooldown()
        )
        #expect(decision == .keep)
    }

    @Test func coolingLineIsSkippedWhenAlternativeExists() {
        let now = Date()
        var cooldown = LineCooldown(duration: 60)
        cooldown.markFailed("lan", at: now.addingTimeInterval(-10))
        let decision = LineRouting.decide(
            lines: [wan, lan], reachableIDs: ["wan", "lan"], access: .lanCapable,
            currentID: "wan", cooldown: cooldown, now: now
        )
        #expect(decision == .keep)
    }

    @Test func cooldownExpires() {
        let now = Date()
        var cooldown = LineCooldown(duration: 60)
        cooldown.markFailed("lan", at: now.addingTimeInterval(-61))
        #expect(!cooldown.isCoolingDown("lan", now: now))
    }

    @Test func coolingLineStillUsedAsLastResort() {
        var cooldown = LineCooldown()
        cooldown.markFailed("lan")
        let decision = LineRouting.decide(
            lines: [wan, lan], reachableIDs: ["lan"], access: .lanCapable,
            currentID: "wan", cooldown: cooldown
        )
        #expect(decision == .switchTo(lan))
    }

    @Test func nothingReachable() {
        let decision = LineRouting.decide(
            lines: [wan, lan], reachableIDs: [], access: .wan, currentID: "wan", cooldown: LineCooldown()
        )
        #expect(decision == .unreachable)
    }

    @Test func offlineNeverSwitches() {
        let decision = LineRouting.decide(
            lines: [wan, lan], reachableIDs: ["lan"], access: .offline, currentID: "wan", cooldown: LineCooldown()
        )
        #expect(decision == .keep)
    }

    @Test func autoNames() {
        #expect(LineRouting.displayName(of: lan) == "局域网")
        #expect(LineRouting.displayName(of: ServerLine(name: " 家宽 ", url: wan.url)) == "家宽")
    }
}
