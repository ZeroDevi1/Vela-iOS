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

    /// mpv / VLC 与 KSPlayer 一样直放原文件；服务器坚持转码（HLS）时一律回到系统内核。
    @Test func mpvAndVLCDirectPlayLikeKSPlayer() {
        #expect(PlaybackEngineChoice.requestedEngine(mode: .mpv, serverDownscaled: false) == .mpv)
        #expect(PlaybackEngineChoice.requestedEngine(mode: .vlc, serverDownscaled: false) == .vlc)
        #expect(PlaybackEngineChoice.requestedEngine(mode: .vlc, serverDownscaled: true) == .system)
        #expect(PlaybackEngineChoice.playbackEngine(requested: .mpv, isDirectPlay: true) == .mpv)
        #expect(PlaybackEngineChoice.playbackEngine(requested: .vlc, isDirectPlay: false) == .system)
        #expect(!PlaybackEngineChoice.switchesToKSPlayerForSubtitle(mode: .mpv, requested: .mpv, serverDownscaled: false, subtitleNeedsPlayer: true))
    }

    /// 新内核的存储值不能与旧版本保存的 "mpv"（已迁移为 KSPlayer）冲突。
    @Test func newEngineRawValuesDoNotCollideWithLegacyValue() {
        #expect(PlaybackEngineMode(rawValue: "mpv") == nil)
        #expect(PlaybackEngineMode.mpv.rawValue == "libmpv")
    }
}
