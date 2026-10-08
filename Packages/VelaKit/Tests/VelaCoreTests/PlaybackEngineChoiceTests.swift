import Testing
@testable import VelaCore

/// 起播内核选择：请求能力档 → 是否因内嵌字幕改用 KSPlayer → 实际内核。
struct PlaybackEngineChoiceTests {
    @Test func requestedEngineFollowsModeUnlessServerDownscaled() {
        #expect(PlaybackEngineChoice.requestedEngine(mode: .ksPlayer, serverDownscaled: false) == .ksPlayer)
        // 「服务器转码为 4K」的码流只能交给系统内核。
        #expect(PlaybackEngineChoice.requestedEngine(mode: .ksPlayer, serverDownscaled: true) == .system)
        #expect(PlaybackEngineChoice.requestedEngine(mode: .auto, serverDownscaled: false) == .system)
        #expect(PlaybackEngineChoice.requestedEngine(mode: .system, serverDownscaled: false) == .system)
    }

    @Test func onlyAutoModeSwitchesForPlayerSideSubtitle() {
        #expect(PlaybackEngineChoice.switchesToKSPlayerForSubtitle(mode: .auto, requested: .system, serverDownscaled: false, subtitleNeedsPlayer: true))
        #expect(!PlaybackEngineChoice.switchesToKSPlayerForSubtitle(mode: .system, requested: .system, serverDownscaled: false, subtitleNeedsPlayer: true))
        #expect(!PlaybackEngineChoice.switchesToKSPlayerForSubtitle(mode: .auto, requested: .system, serverDownscaled: true, subtitleNeedsPlayer: true))
        #expect(!PlaybackEngineChoice.switchesToKSPlayerForSubtitle(mode: .auto, requested: .system, serverDownscaled: false, subtitleNeedsPlayer: false))
        #expect(!PlaybackEngineChoice.switchesToKSPlayerForSubtitle(mode: .ksPlayer, requested: .ksPlayer, serverDownscaled: false, subtitleNeedsPlayer: true))
    }

    @Test func transcodedStreamAlwaysUsesSystemEngine() {
        #expect(PlaybackEngineChoice.playbackEngine(requested: .ksPlayer, isDirectPlay: true) == .ksPlayer)
        #expect(PlaybackEngineChoice.playbackEngine(requested: .ksPlayer, isDirectPlay: false) == .system)
        #expect(PlaybackEngineChoice.playbackEngine(requested: .system, isDirectPlay: true) == .system)
    }

    /// 已移除的 mpv / VLC 存储值不再解析（设置读取时回到默认值），旧版的 "mpv" 也不会被误认。
    @Test func removedEngineRawValuesAreRejected() {
        #expect(PlaybackEngineMode(rawValue: "mpv") == nil)
        #expect(PlaybackEngineMode(rawValue: "libmpv") == nil)
        #expect(PlaybackEngineMode(rawValue: "vlc") == nil)
    }
}
