import Testing
@testable import VelaCore

struct TrackLabelTests {
    @Test func japaneseAudioWithRatesAndDefault() {
        let label = TrackLabelFormatter.label(for: TrackAttributes(
            kind: .audio, index: 1, language: "jpn",
            displayTitle: "Japanese AC3 stereo (默认)",
            sampleRate: 48_000, bitRate: 192_000, isDefault: true
        ))
        #expect(label.title == "Japanese AC3 stereo")
        #expect(label.languageName == "日语")
        #expect(label.detailLine == "日语 · 48 kHz · 192 kbps · 默认")
    }

    @Test func chineseAudioIsMandarinUnlessCantonese() {
        #expect(TrackLabelFormatter.languageName(code: "chi", hints: ["Chinese AAC stereo"], kind: .audio) == "国语")
        #expect(TrackLabelFormatter.languageName(code: "chi", hints: ["Cantonese"], kind: .audio) == "粤语")
        #expect(TrackLabelFormatter.languageName(code: "yue", kind: .audio) == "粤语")
    }

    @Test func chineseSubtitleVariants() {
        #expect(TrackLabelFormatter.languageName(code: "chi", hints: ["Chinese Simplified (ASS)"], kind: .subtitle) == "简体中文")
        #expect(TrackLabelFormatter.languageName(code: "chi", hints: ["Chinese Traditional"], kind: .subtitle) == "繁体中文")
        #expect(TrackLabelFormatter.languageName(code: "zh-TW", kind: .subtitle) == "繁体中文")
        #expect(TrackLabelFormatter.languageName(code: "chs", kind: .subtitle) == "简体中文")
        #expect(TrackLabelFormatter.languageName(code: "zho", hints: ["简繁双语"], kind: .subtitle) == "简繁中文")
        #expect(TrackLabelFormatter.languageName(code: "chi", hints: ["Chinese"], kind: .subtitle) == "中文")
    }

    @Test func untaggedExternalSubtitleUsesTitleHints() {
        #expect(TrackLabelFormatter.languageName(code: nil, hints: ["简日双语"], kind: .subtitle) == "简体中文")
        #expect(TrackLabelFormatter.languageName(code: nil, hints: ["Signs"], kind: .subtitle) == nil)
    }

    @Test func unknownCodesAreHidden() {
        #expect(TrackLabelFormatter.languageName(code: "und", kind: .audio) == nil)
        #expect(TrackLabelFormatter.languageName(code: "", kind: .audio) == nil)
    }

    @Test func flagsAndSuffixStripping() {
        let label = TrackLabelFormatter.label(for: TrackAttributes(
            kind: .subtitle, index: 3, language: "eng",
            displayTitle: "English - SUBRIP - Forced - External",
            isForced: true, isExternal: true
        ))
        #expect(label.title == "English - SUBRIP")
        #expect(label.detailLine == "英语 · 强制 · 外挂")
    }

    @Test func fallbackTitle() {
        let label = TrackLabelFormatter.label(for: TrackAttributes(kind: .audio, index: 2))
        #expect(label.title == "音轨 2")
        #expect(label.detailLine == nil)
    }
}

struct TrackTitleCleanupTests {
    @Test func flagInsideParentheses() {
        #expect(TrackLabelFormatter.stripFlagSuffixes("Chinese Simplified (默认 ASS)") == "Chinese Simplified (ASS)")
        #expect(TrackLabelFormatter.stripFlagSuffixes("Chinese Traditional (ASS)") == "Chinese Traditional (ASS)")
        #expect(TrackLabelFormatter.stripFlagSuffixes("Japanese (Default Forced) AAC") == "Japanese AAC")
    }
}

struct SubtitleCodecTitleTests {
    /// Emby 给无标题字幕的显示标题只有编码名（「(SUBRIP)」），显示为 SRT。
    @Test func codecOnlyTitleBecomesFormatName() {
        let label = TrackLabelFormatter.label(for: TrackAttributes(kind: .subtitle, index: 3, language: "chi", displayTitle: "(SUBRIP)", codec: "subrip"))
        #expect(label.title == "SRT")
    }
}
