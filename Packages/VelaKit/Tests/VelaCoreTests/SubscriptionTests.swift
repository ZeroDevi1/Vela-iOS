import Foundation
import Testing
@testable import VelaCore

struct CalendarRulesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// 2026-10-05 是周一。
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15))! }

    @Test func bangumiWeekdayMapsWithinNextSevenDays() {
        let sameDay = CalendarRules.nextDate(forBangumiWeekday: 1, today: monday, calendar: calendar)
        #expect(sameDay == calendar.startOfDay(for: monday))
        let sunday = CalendarRules.nextDate(forBangumiWeekday: 7, today: monday, calendar: calendar)!
        #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: monday), to: sunday).day == 6)
        #expect(CalendarRules.nextDate(forBangumiWeekday: 0, today: monday, calendar: calendar) == nil)
    }

    @Test func parsesDayAndWindow() {
        let day = CalendarRules.day(from: "2026-10-01T00:00:00", calendar: calendar)!
        #expect(CalendarRules.isInWindow(day, today: monday, calendar: calendar))
        let old = CalendarRules.day(from: "2026-09-20", calendar: calendar)!
        #expect(!CalendarRules.isInWindow(old, today: monday, calendar: calendar))
        #expect(CalendarRules.day(from: "2026", calendar: calendar) == nil)
    }

    @Test func subscriptionTypeAndCatalog() {
        #expect(SubscriptionRecord.mediaType(fromMoviePilot: "电视剧") == .tv)
        #expect(SubscriptionRecord.mediaType(fromMoviePilot: "其他") == nil)
        let record = SubscriptionRecord(id: 3, name: "剧", mediaType: .tv, season: 2, tmdbID: 99, year: "2024", state: "R")
        #expect(record.catalogTitle?.id == "tv/99")
        #expect(record.stateText == "订阅中")
        #expect(SubscriptionRecord(id: 4, name: "x").catalogTitle == nil)
    }

    @Test func episodeLabel() {
        let entry = CalendarEntry(id: "a", title: "T", date: monday, season: 1, episode: 5, episodeName: "名")
        #expect(entry.episodeLabel == "S01E05 · 名")
    }
}

struct EngineChoiceTests {
    @Test func autoSwitchesOnlyForFormatTranscodes() {
        #expect(PlaybackEngineChoice.prefersMPV(mode: .auto, isTranscode: true, reasons: ["ContainerNotSupported"], canDirectStream: true))
        #expect(!PlaybackEngineChoice.prefersMPV(mode: .auto, isTranscode: false, reasons: [], canDirectStream: true))
        #expect(!PlaybackEngineChoice.prefersMPV(mode: .auto, isTranscode: true, reasons: ["ContainerBitrateExceedsLimit"], canDirectStream: true))
        #expect(!PlaybackEngineChoice.prefersMPV(mode: .auto, isTranscode: true, reasons: ["VideoCodecNotSupported"], canDirectStream: false))
    }

    @Test func explicitModes() {
        #expect(PlaybackEngineChoice.prefersMPV(mode: .mpv, isTranscode: false, reasons: [], canDirectStream: true))
        #expect(!PlaybackEngineChoice.prefersMPV(mode: .system, isTranscode: true, reasons: ["ContainerNotSupported"], canDirectStream: true))
    }
}

struct TraktScrobbleTests {
    @Test func movieUsesTMDBAndIMDb() {
        let item = MediaItem(id: "1", serverID: "s", name: "M", kind: .movie, providerIDs: ["tmdb": "10", "imdb": "tt1", "douban": "x"])
        #expect(TraktScrobble.body(for: item) == ["movie": ["ids": ["tmdb": "10", "imdb": "tt1"]]])
    }

    @Test func episodeUsesOwnIDsAndSkipsWhenMissing() {
        let episode = MediaItem(id: "2", serverID: "s", name: "E", kind: .episode, providerIDs: ["tvdb": "99"])
        #expect(TraktScrobble.body(for: episode) == ["episode": ["ids": ["tvdb": "99"]]])
        let bare = MediaItem(id: "3", serverID: "s", name: "E", kind: .episode)
        #expect(TraktScrobble.body(for: bare) == nil)
    }

    @Test func progressClamps() {
        #expect(TraktScrobble.progress(position: 50, duration: 100) == 50)
        #expect(TraktScrobble.progress(position: 150, duration: 100) == 100)
        #expect(TraktScrobble.progress(position: 5, duration: 0) == 0)
    }
}

struct DownloadTests {
    @Test func idsAndBitrates() {
        let record = DownloadRecord(serverID: "s", itemID: "i", title: "T", subtitle: nil, posterURL: nil, quality: .medium, isHLS: true)
        #expect(record.id == "s/i/medium")
        #expect(record.state == .queued)
        #expect(DownloadQuality.original.maxBitrate == nil)
        #expect(DownloadQuality.low.maxBitrate == 1_500_000)
    }

    @Test func offlineEngineByExtension() {
        #expect(OfflinePlayback.prefersSystemEngine(for: URL(fileURLWithPath: "/a/b.movpkg")))
        #expect(OfflinePlayback.prefersSystemEngine(for: URL(fileURLWithPath: "/a/b.MP4")))
        #expect(!OfflinePlayback.prefersSystemEngine(for: URL(fileURLWithPath: "/a/b.mkv")))
    }
}
