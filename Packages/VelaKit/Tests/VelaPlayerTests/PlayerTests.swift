import CoreGraphics
import CoreVideo
import Metal
import simd
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

    @Test func dmmContentIDWithNumericPrefix() {
        for path in ["/vr/1sivr00123-cd1.mp4", "h_1155crvr00123.mp4", "3DSVR-0456-A.mp4", "URVRSP-123.mp4", "VRKM-1234-cd2.mp4"] {
            #expect(VRLayoutParser.parse(mediaSourcePath: path)?.projection == .halfEquirect, "\(path)")
        }
    }

    @Test func standaloneVRWord() {
        #expect(VRLayoutParser.parse(itemName: "某作品 【VR】 前編")?.projection == .halfEquirect)
        #expect(VRLayoutParser.parse(mediaSourcePath: "Title_8KVR_part1.mp4")?.projection == .halfEquirect)
        #expect(VRLayoutParser.parse(mediaSourcePath: "Title VR.mp4")?.projection == .halfEquirect)
        #expect(VRLayoutParser.parse(itemName: "SIVR-357 【VR】可愛い", videoWidth: 3840, videoHeight: 2160) == nil)
    }

    @Test func explicit360WinsOverVRCode() {
        #expect(VRLayoutParser.parse(mediaSourcePath: "Travel_vr360.mp4")?.projection == .equirect)
    }

    @Test func ignoresWordsMerelyContainingVR() {
        #expect(VRLayoutParser.parse(mediaSourcePath: "/movies/Overdrive (2017).mkv") == nil)
        #expect(VRLayoutParser.parse(mediaSourcePath: "/movies/DVR Recording.ts", videoWidth: 1920, videoHeight: 1080) == nil)
        #expect(VRLayoutParser.parse(itemName: "Silver Linings") == nil)
    }

    @Test func serverTagRoundTrips() {
        for layout in VRLayoutParser.manualOptions {
            #expect(VRLayoutParser.parse(itemName: "Holiday Clip", tags: [layout.serverTag]) == layout, "\(layout.serverTag)")
        }
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
        // 开启「中间切换媒体」：中间三分之一判为切换媒体，两侧仍为亮度 / 音量。
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 2, height: -30), startX: 200, width: 400, switchMediaZone: true) == .switchMedia)
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 2, height: -30), startX: 50, width: 400, switchMediaZone: true) == .brightness)
        #expect(PlayerGestureModel.panKind(translation: CGSize(width: 2, height: -30), startX: 350, width: 400, switchMediaZone: true) == .volume)
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

struct ASSParserTests {
    @Test func parsesDialogueWithCommasAndOverrideTags() {
        let ass = """
        [Script Info]
        Title: 示例

        [V4+ Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\an8\\fs20}第二条，含逗号
        Dialogue: 0,0:00:01.20,0:00:03.00,Default,,0,0,0,,第一行\\N第二行
        Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,注释不显示
        """
        let cues = SubtitleFileParser.parse(ass, fileExtension: "ASS")
        #expect(cues.count == 2)
        #expect(cues[0] == SubtitleCue(start: 1.2, end: 3, text: "第一行\n第二行"))
        #expect(cues[1].text == "第二条，含逗号")
        #expect(cues[1].end == 7.5)
    }

    @Test func srtUsesWebVTTParser() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
        #expect(SubtitleFileParser.parse(srt, fileExtension: "srt") == [SubtitleCue(start: 1, end: 2, text: "你好")])
    }
}

struct VRProjectionTests {
    private let sbs180 = VRLayout(projection: .halfEquirect, stereo: .sideBySide, inputFOV: 180)

    @Test func centerMapsToLeftEyeCenter() {
        let uv = VRProjection.sourceUV(ndc: .zero, aspect: 16.0 / 9, view: VRViewState(), layout: sbs180)
        #expect(abs(uv!.x - 0.25) < 1e-9)
        #expect(abs(uv!.y - 0.5) < 1e-9)
    }

    @Test func yawAndPitchMoveTheSample() {
        let mono = VRLayout(projection: .halfEquirect, stereo: .mono, inputFOV: 180)
        let right = VRProjection.sourceUV(ndc: .zero, aspect: 1, view: VRViewState(yaw: 45), layout: mono)!
        #expect(abs(right.x - 0.75) < 1e-9)
        let up = VRProjection.sourceUV(ndc: .zero, aspect: 1, view: VRViewState(pitch: 30), layout: mono)!
        #expect(up.y < 0.5)
    }

    @Test func outsideHalfSphereIsBlack() {
        let mono = VRLayout(projection: .halfEquirect, stereo: .mono, inputFOV: 180)
        #expect(VRProjection.sourceUV(ndc: SIMD2(1, 0), aspect: 2, view: VRViewState(yaw: 90, outputFOV: 150), layout: mono) == nil)
    }

    @Test func fisheyeCenterAndTopBottom() {
        let fisheye = VRLayout(projection: .fisheye, stereo: .topBottom, inputFOV: 200)
        let uv = VRProjection.sourceUV(ndc: .zero, aspect: 1, view: VRViewState(), layout: fisheye)!
        #expect(abs(uv.x - 0.5) < 1e-9)
        #expect(abs(uv.y - 0.25) < 1e-9)
    }

    @Test func dragClampsAndPanoramaWraps() {
        var state = VRViewState()
        state.drag(by: CGSize(width: -10_000, height: 0), viewSize: CGSize(width: 1000, height: 500), layout: sbs180)
        #expect(state.yaw == 90)
        var panorama = VRViewState(yaw: 170)
        panorama.drag(by: CGSize(width: -200, height: 0), viewSize: CGSize(width: 1000, height: 500),
                      layout: VRLayout(projection: .equirect, stereo: .mono, inputFOV: 360))
        #expect(panorama.yaw < 0)
    }

    @Test func rotateClampsPitchAndYaw() {
        var state = VRViewState()
        state.rotate(yaw: 120, pitch: 200, layout: sbs180)
        #expect(state.yaw == 90)
        #expect(state.pitch == 90)
    }

    @Test func zoomClamps() {
        var state = VRViewState()
        state.zoom(by: 100)
        #expect(state.outputFOV == VRViewport.minOutputFOV)
        state.zoom(by: 0.001)
        #expect(state.outputFOV == VRViewport.maxOutputFOV)
    }
}

struct VRMotionTrackerTests {
    // 参考系 Z 轴竖直向上；设备 -Z（屏幕背面）为视线。
    @Test func flatDeviceLooksDown() {
        let result = VRMotionTracker.orientation(of: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)))
        #expect(abs(result.pitch + 90) < 1e-9)
        #expect(result.heading == nil)
    }

    @Test func turningRightIncreasesHeadingAndTiltingUpIncreasesPitch() throws {
        // 竖起设备（绕设备 X 轴 +90°）：视线水平。
        let upright = simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        let base = VRMotionTracker.orientation(of: upright)
        #expect(abs(base.pitch) < 1e-9)
        // 绕竖直轴顺时针（俯视）转 30°，即向右转。
        let right = VRMotionTracker.orientation(of: simd_quatd(angle: -.pi / 6, axis: SIMD3(0, 0, 1)) * upright)
        let delta = VRMotionTracker.wrap(try #require(right.heading) - #require(base.heading))
        #expect(abs(delta - 30) < 1e-9)
        // 再竖起 20°：视线抬高。
        let tilted = VRMotionTracker.orientation(of: simd_quatd(angle: .pi / 2 + .pi / 9, axis: SIMD3(1, 0, 0)))
        #expect(abs(tilted.pitch - 20) < 1e-9)
    }

    @Test func wrapAcrossBoundary() {
        #expect(VRMotionTracker.wrap(350) == -10)
        #expect(VRMotionTracker.wrap(-350) == 10)
    }
}

struct VRShaderTests {
    /// 着色器在运行时编译，语法错误只会在开启 VR 时暴露；这里提前编译一次。
    @MainActor @Test func shaderCompiles() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil, "当前环境没有 Metal 设备")
        #expect(VRRenderer(layout: VRLayout(projection: .fisheye, stereo: .sideBySide, inputFOV: 200)) != nil)
    }
}

struct VRTextureTests {
    /// 视频输出按这组属性分配缓冲区；缺少 IOSurface / Metal 兼容声明时纹理创建失败，画面全黑。
    @Test func outputBuffersAreMetalCompatible() throws {
        let textures = try makeTextures(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(textures.mode == 0)
        #expect(CVMetalTextureGetTexture(textures.luma)?.width == 64)
        #expect(textures.chroma.flatMap(CVMetalTextureGetTexture)?.width == 32)
    }

    /// KSPlayer 的 10 位 HEVC 硬解输出（x420）按 16 位纹理读取。
    @Test func tenBitFramesUseSixteenBitTextures() throws {
        let textures = try makeTextures(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(CVMetalTextureGetTexture(textures.luma)?.pixelFormat == .r16Unorm)
        #expect(textures.chroma.flatMap(CVMetalTextureGetTexture)?.pixelFormat == .rg16Unorm)
    }

    /// KSPlayer 软解输出的 I420（y420）：三个单通道平面。
    @Test func planarFramesUseThreeTextures() throws {
        let textures = try makeTextures(format: kCVPixelFormatType_420YpCbCr8Planar)
        #expect(textures.mode == 3)
        #expect(textures.chromaRed.flatMap(CVMetalTextureGetTexture)?.width == 32)
    }

    @Test func bgraFramesSampleRGBDirectly() throws {
        let textures = try makeTextures(format: kCVPixelFormatType_32BGRA)
        #expect(textures.mode == 2)
        #expect(textures.chroma == nil)
    }

    private func makeTextures(format: OSType) throws -> VRRenderer.VRFrameTextures {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        var buffer: CVPixelBuffer?
        let created = CVPixelBufferCreate(nil, 64, 32, format, VRRenderer.pixelBufferAttributes as CFDictionary, &buffer)
        #expect(created == kCVReturnSuccess)
        return try VRRenderer.makeTextures(from: try #require(buffer), cache: try #require(cache)).get()
    }
}

struct VRPreviewFlattenerTests {
    /// 180° 单眼片源正前方：输出中心取源画面中心，与着色器取景一致。
    @Test func centerOfOutputSamplesCenterOfSource() throws {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let central = (24..<40).contains(x) && (24..<40).contains(y)
                pixels[i] = central ? 0 : 255
                pixels[i + 1] = central ? 255 : 0
                pixels[i + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let source = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let layout = VRLayout(projection: .halfEquirect, stereo: .mono, inputFOV: 180)
        let output = try #require(VRPreviewFlattener.flatten(source, layout: layout, view: VRViewState(), outputSize: CGSize(width: 32, height: 18)))
        #expect(output.width == 32 && output.height == 18)
        let data = try #require(output.dataProvider?.data as Data?)
        let center = (9 * 32 + 16) * 4
        #expect(data[center + 1] > 200 && data[center] < 50)
    }
}

struct SRTParsingTests {
    /// 字幕改为直接取 SRT 原文：序号行、逗号毫秒、BOM 与 CRLF 都要能解析。
    @Test func parsesRawSRT() {
        let srt = "\u{FEFF}1\r\n00:11:48,100 --> 00:11:50,200\r\n祖父唤孙儿前来\r\n\r\n2\r\n00:11:51,000 --> 00:11:52,500\r\n<i>第二句</i>\r\n"
        let cues = WebVTTParser.parse(srt)
        #expect(cues.count == 2)
        #expect(cues.first?.text == "祖父唤孙儿前来")
        #expect(abs((cues.first?.start ?? 0) - 708.1) < 0.001)
        #expect(cues.last?.text == "第二句")
    }
}

@MainActor
struct VRCapabilityTests {
    private let vrSource = PlaybackSource(
        url: URL(fileURLWithPath: "/dev/null"), title: "vr",
        vrLayout: VRLayout(projection: .halfEquirect, stereo: .sideBySide, inputFOV: 180)
    )

    /// 系统内核与 KSPlayer 都能提供解码画面：VR 片源自动转平面，切换内核后保持开启。
    @Test func vrStaysEnabledWhenSwitchingBetweenEngines() {
        let controller = PlayerController(engine: AVPlayerEngine())
        controller.load(vrSource)
        #expect(controller.vrEnabled)
        controller.replaceEngine(KSPlayerEngine())
        #expect(controller.vrEnabled)
        controller.shutdown()
    }
}

struct ForwardBufferDurationTests {
    @Test func highBitrateResumeThresholdFitsForwardBudget() {
        #expect(PlayerPreferences.rebufferDuration(bitrate: 80_000_000, maximumDuration: 100) == 8)
        #expect(PlayerPreferences.rebufferDuration(bitrate: 80_000_000, maximumDuration: 4) == 4)
        #expect(PlayerPreferences.rebufferDuration(bitrate: 8_000_000, maximumDuration: 100) == 3)
        #expect(PlayerPreferences.rebufferDuration(bitrate: nil, maximumDuration: 0) == 3)
    }
    private let gib: UInt64 = 1 << 30

    @Test func automaticCapsByTimeForLowBitrate() {
        // 10 Mbps 时 1 GB 约 859 秒，Wi-Fi 下受 10 分钟上限约束；蜂窝下受 256 MB 约束（约 215 秒）。
        #expect(PlayerPreferences.forwardBufferDuration(seconds: 0, bitrate: 10_000_000, isMetered: false, physicalMemory: 8 * gib) == 600)
        let metered = PlayerPreferences.forwardBufferDuration(seconds: 0, bitrate: 10_000_000, isMetered: true, physicalMemory: 8 * gib)
        #expect(abs(metered - 214.7) < 0.1)
        #expect(PlayerPreferences.forwardBufferDuration(seconds: 0, bitrate: 2_000_000, isMetered: true, physicalMemory: 8 * gib) == 300)
    }

    @Test func automaticCapsBySizeForHighBitrate() {
        // 80 Mbps、4 GB 内存：预算 512 MB，约 54 秒。
        let duration = PlayerPreferences.forwardBufferDuration(seconds: 0, bitrate: 80_000_000, isMetered: false, physicalMemory: 4 * gib)
        #expect(abs(duration - 53.7) < 0.1)
    }

    @Test func neverBelowThirtySeconds() {
        #expect(PlayerPreferences.forwardBufferDuration(seconds: 0, bitrate: 400_000_000, isMetered: true, physicalMemory: 4 * gib) == 30)
    }

    @Test func manualChoiceOnlyLimitedByMemory() {
        #expect(PlayerPreferences.forwardBufferDuration(seconds: 120, bitrate: 10_000_000, isMetered: true, physicalMemory: 8 * gib) == 120)
        let capped = PlayerPreferences.forwardBufferDuration(seconds: 600, bitrate: 80_000_000, isMetered: false, physicalMemory: 8 * gib)
        #expect(abs(capped - 107.4) < 0.1)
    }

    @Test func unknownBitrateUsesEstimate() {
        // 按 40 Mbps 估算：1 GB 约 215 秒。
        let duration = PlayerPreferences.forwardBufferDuration(seconds: 0, bitrate: nil, isMetered: false, physicalMemory: 8 * gib)
        #expect(abs(duration - 214.7) < 0.1)
    }
}
