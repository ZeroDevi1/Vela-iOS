import CoreVideo
import Foundation
import Testing
@testable import VelaPlayer

/// KSPlayer 补丁 0005：HDR10 静态元数据随解码画面送显。两种硬解方式：异步硬解直接用 `VTDecompressionSession`
/// （码流 SEI 由补丁扫描），否则经 FFmpeg 的 VideoToolbox 硬件加速（元数据来自 FFmpeg 解出的帧附加数据）。
/// 10 bit 软解画面不是 `CVPixelBuffer`，走 Metal 绘制（`CAEDRMetadata`），这里不覆盖。
/// 夹具（1 秒 128×72 HEVC 10 bit PQ，x265 生成）：
/// - `hdr10-sei.mp4`：只有码流 SEI，母版 1000 / 0.005 nits，MaxCLL 1000，MaxFALL 400
/// - `hdr10-container.mp4`：码流无 HDR SEI，只有容器 `mdcv` / `clli`，母版 4000 / 0.0001 nits，MaxCLL 2000，MaxFALL 600
@MainActor
struct HDRMetadataTests {
    @Test func parsesSEIPayloads() throws {
        var mastering = Data(count: 16)
        mastering += [0x00, 0x98, 0x96, 0x80] // 10_000_000 → 1000 nits
        mastering += [0x00, 0x00, 0x00, 0x32] // 50 → 0.005 nits
        let metadata = try #require(HDRStaticMetadata(masteringDisplay: mastering, contentLightLevel: Data([0x03, 0xE8, 0x01, 0x90])))
        #expect(metadata.masteringLuminance?.max == 1000)
        #expect(metadata.masteringLuminance?.min == 0.005)
        #expect(metadata.contentLightLevel?.maxCLL == 1000)
        #expect(metadata.contentLightLevel?.maxFALL == 400)
        #expect(metadata.summary == "母版 1000 / 0.005 nits · MaxCLL 1000 · MaxFALL 400")
        #expect(HDRStaticMetadata(masteringDisplay: Data(count: 10), contentLightLevel: nil) == nil)
    }

    @Test(arguments: [
        ("hdr10-sei", true, 1000.0, 0.005, 1000, 400),
        ("hdr10-sei", false, 1000.0, 0.005, 1000, 400),
        ("hdr10-container", true, 4000.0, 0.0001, 2000, 600),
        ("hdr10-container", false, 4000.0, 0.0001, 2000, 600),
    ])
    func decodedFramesCarryMetadata(fixture: String, asynchronous: Bool, maxNits: Double, minNits: Double, maxCLL: Int, maxFALL: Int) async throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "mp4", subdirectory: "Resources"))
        let engine = KSPlayerEngine()
        engine.configuration.asynchronousDecompression = asynchronous
        engine.setMuted(true)
        engine.load(PlaybackSource(url: url, title: "fixture"))
        defer { engine.stop() }

        var pixelBuffer: CVPixelBuffer?
        for _ in 0..<50 where pixelBuffer == nil {
            try await Task.sleep(for: .milliseconds(100))
            pixelBuffer = engine.currentPixelBuffer()
        }
        let frame = try #require(pixelBuffer, "5 秒内没有解码画面，状态 \(engine.status)")
        let metadata = try #require(HDRStaticMetadata(pixelBuffer: frame), "画面没有 HDR 元数据附件")
        #expect(metadata.masteringLuminance?.max == maxNits)
        #expect(metadata.masteringLuminance?.min == minNits)
        #expect(metadata.contentLightLevel?.maxCLL == maxCLL)
        #expect(metadata.contentLightLevel?.maxFALL == maxFALL)
    }
}
