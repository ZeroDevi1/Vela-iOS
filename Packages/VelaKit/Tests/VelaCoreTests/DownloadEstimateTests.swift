import Testing
@testable import VelaCore

/// 下载前的占用空间估算（与 Android 相同：原文件按大小，转码按码率 × 时长）。
struct DownloadEstimateTests {
    private let hour: Int64 = 3600 * 10_000_000

    @Test func originalUsesFileSize() {
        #expect(DownloadEstimate.bytes(quality: .original, fileSize: 5_000_000_000, sourceBitrate: 20_000_000, runTimeTicks: hour) == 5_000_000_000)
        #expect(DownloadEstimate.bytes(quality: .original, fileSize: nil, sourceBitrate: nil, runTimeTicks: hour) == nil)
    }

    @Test func limitedQualityEstimatesFromBitrateAndDuration() {
        // (4 Mbps + 192 kbps) × 3600 s / 8
        #expect(DownloadEstimate.bytes(quality: .medium, fileSize: 9_000_000_000, sourceBitrate: 20_000_000, runTimeTicks: hour) == 1_886_400_000)
        // 原码率低于上限：下载原文件。
        #expect(DownloadEstimate.bytes(quality: .high, fileSize: 1_000_000_000, sourceBitrate: 2_000_000, runTimeTicks: hour) == 1_000_000_000)
        #expect(DownloadEstimate.bytes(quality: .low, fileSize: nil, sourceBitrate: nil, runTimeTicks: nil) == nil)
    }
}
