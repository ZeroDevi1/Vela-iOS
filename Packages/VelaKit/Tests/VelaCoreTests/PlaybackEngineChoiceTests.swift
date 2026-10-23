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

    /// 阶段 4c：片源有系统内核更擅长的特性时，自动模式不为字幕切到 KSPlayer；P7 两个内核相当，照常切换。
    @Test func autoModeKeepsSystemEngineForSystemOnlyFeatures() {
        func switches(_ limitation: KSPlayerLimitation?) -> Bool {
            PlaybackEngineChoice.switchesToKSPlayerForSubtitle(
                mode: .auto, requested: .system, serverDownscaled: false, subtitleNeedsPlayer: true, limitation: limitation)
        }
        #expect(!switches(.atmosObjects))
        #expect(!switches(.discImage))
        #expect(!switches(.dolbyVisionDecoded(profile: 5)))
        #expect(switches(.dolbyVisionProfile7))
        #expect(switches(nil))
    }

    /// 系统内核失败后只在自动模式、同一条目首次时回退 KSPlayer；超过 4K 宽的无画面留给服务器缩放。
    @Test func fallsBackToKSPlayerAfterSystemFailure() {
        func fallsBack(_ failure: PlaybackEngineChoice.SystemEngineFailure = .error, mode: PlaybackEngineMode = .auto,
                       serverDownscaled: Bool = false, isDiscImage: Bool = false, alreadyFellBack: Bool = false) -> Bool {
            PlaybackEngineChoice.fallsBackToKSPlayer(
                after: failure, mode: mode, serverDownscaled: serverDownscaled, isDiscImage: isDiscImage, alreadyFellBack: alreadyFellBack)
        }
        #expect(fallsBack())
        #expect(!fallsBack(mode: .system))
        #expect(!fallsBack(mode: .ksPlayer))
        #expect(!fallsBack(serverDownscaled: true))
        #expect(!fallsBack(isDiscImage: true))
        #expect(!fallsBack(alreadyFellBack: true))
        #expect(fallsBack(.noVideoOutput(width: 3840)))
        #expect(fallsBack(.noVideoOutput(width: nil)))
        #expect(!fallsBack(.noVideoOutput(width: 7680)))
    }

    @Test func ksPlayerLimitationsBySource() {
        typealias Traits = PlaybackEngineChoice.SourceTraits
        func limitation(_ traits: Traits, passthrough: Bool = true) -> KSPlayerLimitation? {
            PlaybackEngineChoice.ksPlayerLimitation(traits, passthrough: passthrough)
        }
        #expect(limitation(Traits()) == nil)
        // 原盘优先：KSPlayer 无论如何读不了。
        #expect(limitation(Traits(isDiscImage: true, dolbyVisionProfile: 5, isAtmosEAC3: true)) == .discImage)
        // 杜比直通时 P5 / P8 由系统做杜比视界映射，与系统内核相同。
        #expect(limitation(Traits(dolbyVisionProfile: 5)) == nil)
        #expect(limitation(Traits(dolbyVisionProfile: 8)) == nil)
        #expect(limitation(Traits(dolbyVisionProfile: 5), passthrough: false) == .dolbyVisionDecoded(profile: 5))
        #expect(limitation(Traits(dolbyVisionProfile: 8, isAtmosEAC3: true), passthrough: false) == .dolbyVisionDecoded(profile: 8))
        #expect(limitation(Traits(dolbyVisionProfile: 8, isAtmosEAC3: true)) == .atmosObjects)
        #expect(limitation(Traits(dolbyVisionProfile: 7)) == .dolbyVisionProfile7)
        #expect(limitation(Traits(isAtmosEAC3: true), passthrough: false) == .atmosObjects)
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
