import Testing
@testable import VelaCore

struct BackdropToneTests {
    @Test func keepsHueAndDarkensBrightColor() throws {
        // 鲜红海报：色相保留，亮度压到固定暗区间，饱和度封顶。
        let tone = try #require(BackdropTone.darkTone(red: 0.9, green: 0.1, blue: 0.1))
        #expect(abs(tone.hue - 0) < 0.001)
        #expect(tone.saturation == BackdropTone.maxSaturation)
        #expect(tone.brightness == BackdropTone.brightness)
    }

    @Test func blueHue() throws {
        let tone = try #require(BackdropTone.darkTone(red: 0.1, green: 0.2, blue: 0.6))
        #expect(abs(tone.hue - 0.6333) < 0.001)
    }

    @Test func lowSaturationKeepsMutedTone() throws {
        let tone = try #require(BackdropTone.darkTone(red: 0.5, green: 0.45, blue: 0.4))
        #expect(tone.saturation < 0.25)
    }

    /// 灰色 / 黑白海报不上色，回退纯黑背景。
    @Test func grayPosterHasNoTone() {
        #expect(BackdropTone.darkTone(red: 0.5, green: 0.5, blue: 0.49) == nil)
        #expect(BackdropTone.darkTone(red: 0, green: 0, blue: 0) == nil)
    }
}
