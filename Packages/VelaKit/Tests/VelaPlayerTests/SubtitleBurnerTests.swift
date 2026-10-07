import CoreVideo
import Testing
@testable import VelaPlayer

/// 画中画字幕：字幕必须真的画进帧里，且 KSPlayer 用的输出不能改变帧格式（否则显示图层重建、画中画中断）。
struct SubtitleBurnerTests {
    private func blackFrame(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, format, attributes, &buffer)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        if CVPixelBufferIsPlanar(frame) {
            // 视频范围的黑色：Y = 16，CbCr = 128。
            memset(CVPixelBufferGetBaseAddressOfPlane(frame, 0), 16, CVPixelBufferGetBytesPerRowOfPlane(frame, 0) * height)
            for plane in 1..<CVPixelBufferGetPlaneCount(frame) {
                memset(CVPixelBufferGetBaseAddressOfPlane(frame, plane), 128, CVPixelBufferGetBytesPerRowOfPlane(frame, plane) * height / 2)
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetBytesPerRow(frame) * height)
        }
        return frame
    }

    /// 底部 15% 区域内最亮的像素（BGRA 取 G 通道，YUV 取 Y 平面）。
    private func brightestNearBottom(_ frame: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let planar = CVPixelBufferIsPlanar(frame)
        let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(frame, 0) : CVPixelBufferGetBaseAddress(frame))!
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, 0) : CVPixelBufferGetBytesPerRow(frame)
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        var brightest: UInt8 = 0
        // 图像行序自上而下，字幕在底部 5% 起向上的区域。
        for y in Int(Double(height) * 0.8)..<height {
            for x in stride(from: 0, to: width, by: 2) {
                let value = planar ? base[y * bytesPerRow + x] : base[y * bytesPerRow + x * 4 + 1]
                brightest = max(brightest, value)
            }
        }
        return brightest
    }

    @Test func downscaledOutputContainsSubtitle() throws {
        let burner = SubtitleBurner()
        let source = try blackFrame(width: 1920, height: 1080, format: kCVPixelFormatType_32BGRA)
        #expect(brightestNearBottom(try #require(burner.render(source))) < 30, "没有字幕时应保持黑画面")

        burner.setText("画中画字幕测试")
        let output = try #require(burner.render(source))
        #expect(CVPixelBufferGetWidth(output) == SubtitleBurner.maxOutputWidth)
        #expect(CVPixelBufferGetHeight(output) == 720)
        #expect(brightestNearBottom(output) > 200, "字幕应以白字画在画面底部")
    }

    @Test func formatPreservingOutputKeepsSizeAndFormat() throws {
        let burner = SubtitleBurner()
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let source = try blackFrame(width: 1920, height: 1080, format: format)
        #expect(burner.burnPreservingFormat(source) == nil, "没有字幕时返回 nil，直接显示原帧")

        burner.setText("Subtitle")
        let output = try #require(burner.burnPreservingFormat(source))
        #expect(CVPixelBufferGetPixelFormatType(output) == format)
        #expect(CVPixelBufferGetWidth(output) == 1920)
        #expect(CVPixelBufferGetHeight(output) == 1080)
        #expect(brightestNearBottom(output) > 180, "字幕应画进亮度平面")
    }

    /// 回归：KSPlayer 软解输出三平面 `y420`，CoreImage 不支持读写该格式，曾导致小窗绿屏且没有字幕。
    /// 现改为在 CPU 上把字幕混合进亮度 / 色度平面，格式、尺寸不变，字幕区域以外保持原样。
    @Test func threePlanarFramesGetSubtitleWithoutCoreImage() throws {
        let burner = SubtitleBurner()
        let format = kCVPixelFormatType_420YpCbCr8Planar
        let source = try blackFrame(width: 1280, height: 720, format: format)
        burner.setText("三平面字幕")
        let output = try #require(burner.burnPreservingFormat(source))
        #expect(CVPixelBufferGetPixelFormatType(output) == format)
        #expect(CVPixelBufferGetWidth(output) == 1280)
        #expect(CVPixelBufferGetHeight(output) == 720)
        #expect(brightestNearBottom(output) > 180, "字幕应画进亮度平面")

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        // 画面上半部分没有字幕：亮度保持视频范围的黑（16），色度保持 128，不能出现全 0 的「绿屏」。
        let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
        let cb = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt8.self)
        #expect(luma[100 * CVPixelBufferGetBytesPerRowOfPlane(output, 0) + 640] == 16)
        #expect(cb[50 * CVPixelBufferGetBytesPerRowOfPlane(output, 1) + 320] == 128)
    }

    /// CoreImage 与 CPU 混合都不支持的格式：返回 nil（显示原帧、不叠字幕），而不是送出空白帧。
    @Test func unsupportedFormatFallsBackToOriginalFrame() throws {
        let burner = SubtitleBurner()
        burner.setText("Subtitle")
        let source = try blackFrame(width: 640, height: 360, format: kCVPixelFormatType_422YpCbCr8)
        #expect(burner.burnPreservingFormat(source) == nil)
    }
}
