import Foundation
import Testing
@testable import VelaPlayer

/// KSPlayer 内核从视频流读取内嵌文本字幕（与 Android / SenPlayer 相同），不依赖服务器提取。
/// 夹具：10 秒 MKV，内嵌 SRT（0.5–4 秒「第一句字幕」，4.5–9 秒「第二句字幕」）。
@MainActor
struct KSPlayerSubtitleTests {
    @Test func readsEmbeddedSRTFromStream() async throws {
        let url = try #require(Bundle.module.url(forResource: "embedded-subtitle", withExtension: "mkv", subdirectory: "Resources"))
        let engine = KSPlayerEngine()
        engine.setMuted(true)
        engine.load(PlaybackSource(url: url, title: "fixture"))
        engine.selectEmbeddedSubtitle(ordinal: 0)
        defer { engine.stop() }

        var seen: Set<String> = []
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(100))
            if let text = engine.embeddedSubtitleText(at: engine.preciseCurrentTime) { seen.insert(text) }
            if seen.contains("第二句字幕") { break }
        }
        #expect(engine.hasEmbeddedSubtitle)
        #expect(seen.contains("第一句字幕") || seen.contains("第二句字幕"), "播放 12 秒内没有读到任何内嵌字幕，状态 \(engine.status)")
    }

    /// 回归：KSPlayer 的查询会取走命中的字幕条目，引擎须自行保留到结束时间，
    /// 否则字幕只在第一次查询时出现、随后立即消失（真机「字幕一闪就没」）。
    @Test func embeddedSubtitleStaysVisibleUntilItsEnd() async throws {
        let url = try #require(Bundle.module.url(forResource: "embedded-subtitle", withExtension: "mkv", subdirectory: "Resources"))
        let engine = KSPlayerEngine()
        engine.setMuted(true)
        engine.load(PlaybackSource(url: url, title: "fixture"))
        engine.selectEmbeddedSubtitle(ordinal: 0)
        defer { engine.stop() }

        // 第二句字幕覆盖 4.5–9 秒：首次出现后，到 8.5 秒之前的每次查询都应仍是它。
        var firstSeen = false
        var misses: [TimeInterval] = []
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(80))
            let time = engine.preciseCurrentTime
            let text = engine.embeddedSubtitleText(at: time)
            if text == "第二句字幕" { firstSeen = true } else if firstSeen, time < 8.5 { misses.append(time) }
            if time >= 8.5 { break }
        }
        #expect(firstSeen, "没有读到第二句字幕，状态 \(engine.status)")
        #expect(misses.isEmpty, "字幕在结束前消失，时刻：\(misses)")
    }
}
