import CoreGraphics
import Testing
@testable import VelaPlayer

struct VRLayoutParserTests {
    @Test func requiresProjectionToken() {
        #expect(VRLayoutParser.parse(itemName: "180 Days") == nil)
        #expect(VRLayoutParser.parse(mediaSourcePath: "/movies/Avatar.2009.mkv") == nil)
    }

    @Test func detectsHalfEquirectSBS() {
        let layout = VRLayoutParser.parse(mediaSourcePath: "/vr/clip_VR180_SBS.mp4")
        #expect(layout == VRLayout(projection: .halfEquirect, stereo: .sideBySide, inputFOV: 180))
    }

    @Test func detectsFisheyeWithFOV() {
        let layout = VRLayoutParser.parse(mediaSourcePath: "/vr/scene_MKX200_LR.mp4")
        #expect(layout == VRLayout(projection: .fisheye, stereo: .sideBySide, inputFOV: 200))
    }

    @Test func javStudioCodeIsHalfEquirect() {
        let layout = VRLayoutParser.parse(itemName: "SIVR-123 something")
        #expect(layout?.projection == .halfEquirect)
    }

    @Test func rejectsFlattenedSixteenByNine() {
        #expect(VRLayoutParser.parse(mediaSourcePath: "/vr/clip_vr180.mp4", videoWidth: 3840, videoHeight: 2160) == nil)
    }

    @Test func infersStereoFromAspectRatio() {
        // 360° 单眼 2:1，上下排布后为 1:1。
        let layout = VRLayoutParser.parse(mediaSourcePath: "/vr/tour_360.mp4", videoWidth: 4096, videoHeight: 4096)
        #expect(layout?.stereo == .topBottom)
    }

    @Test func video3DFormatFillsStereo() {
        let layout = VRLayoutParser.parse(tags: ["vr180"], video3DFormat: "FullTopAndBottom")
        #expect(layout?.stereo == .topBottom)
    }
}

struct GestureModelTests {
    @Test func tapZonesLandscape() {
        #expect(PlayerGestureModel.tapZone(x: 100, width: 1000, isLandscape: true) == .leading)
        #expect(PlayerGestureModel.tapZone(x: 500, width: 1000, isLandscape: true) == .center)
        #expect(PlayerGestureModel.tapZone(x: 900, width: 1000, isLandscape: true) == .trailing)
    }

    @Test func tapZonesPortraitAreWider() {
        #expect(PlayerGestureModel.tapZone(x: 350, width: 1000, isLandscape: false) == .leading)
        #expect(PlayerGestureModel.tapZone(x: 500, width: 1000, isLandscape: false) == .center)
    }

    @Test func panKindWaitsForThreshold() {
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 5, height: 3), startX: 10, width: 400) == nil)
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 40, height: 3), startX: 10, width: 400) == .seek)
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 2, height: -30), startX: 10, width: 400) == .brightness)
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 2, height: -30), startX: 300, width: 400) == .volume)
    }

    @Test func seekOffsetIsClamped() {
        // 两小时影片：整屏 = 1440 秒（总时长 1/5），上限 600 秒。
        #expect(PlayerGestureModel.seekOffset(translationX: 400, width: 400, duration: 7200) == 600)
        // 两分钟短片：整屏下限 60 秒。
        #expect(PlayerGestureModel.seekOffset(translationX: 200, width: 400, duration: 120) == 30)
    }
}

struct WebVTTTests {
    private let sample = """
    WEBVTT

    1
    00:00:01.000 --> 00:00:03.500 line:90%
    <i>Hello</i> {\\an8}world

    00:00:03.000 --> 00:00:05.000
    第二行 &amp; 重叠

    01:00:00,000 --> 01:00:02,000
    SRT 风格时间
    """

    @Test func parsesCuesAndStripsMarkup() {
        let cues = WebVTTParser.parse(sample)
        #expect(cues.count == 3)
        #expect(cues[0] == SubtitleCue(start: 1, end: 3.5, text: "Hello world"))
        #expect(cues[1].text == "第二行 & 重叠")
        #expect(cues[2].start == 3600)
    }

    @Test func lookupMergesOverlappingCuesAndAppliesDelay() {
        var track = SubtitleTrack(cues: WebVTTParser.parse(sample))
        #expect(track.text(at: 0.5) == nil)
        #expect(track.text(at: 2) == "Hello world")
        #expect(track.text(at: 3.2) == "Hello world\n第二行 & 重叠")
        #expect(track.text(at: 4.5) == "第二行 & 重叠")
        track.delay = 1
        #expect(track.text(at: 2) == "Hello world")
        #expect(track.text(at: 1.5) == nil)
    }
}
