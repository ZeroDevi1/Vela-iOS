import Testing
@testable import VelaPlayer

struct PlaybackMediaInfoTests {
    @Test func defaultsAllFieldsToNil() {
        let info = PlaybackMediaInfo()

        #expect(info.video == nil)
        #expect(info.videoParameters == nil)
        #expect(info.dynamicRange == nil)
        #expect(info.audio == nil)
        #expect(info.audioStreamIndex == nil)
    }

    @Test func preservesExistingInitializerWithoutStreamIndex() {
        let info = PlaybackMediaInfo(
            video: "HEVC",
            videoParameters: "3840 × 2160",
            dynamicRange: "HDR10",
            audio: "AAC"
        )

        #expect(info.video == "HEVC")
        #expect(info.videoParameters == "3840 × 2160")
        #expect(info.dynamicRange == "HDR10")
        #expect(info.audio == "AAC")
        #expect(info.audioStreamIndex == nil)
    }

    @Test(arguments: [0, 3])
    func retainsAudioStreamIndex(index: Int) {
        let info = PlaybackMediaInfo(audio: "AAC", audioStreamIndex: index)

        #expect(info.audio == "AAC")
        #expect(info.audioStreamIndex == index)
    }
}
