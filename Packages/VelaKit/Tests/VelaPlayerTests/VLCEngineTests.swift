import AppKit
import Foundation
import Testing
@testable import VelaPlayer

/// 串行执行：并行时两个 VLC 播放器同时起播，macOS 的 OpenGL 视频输出与主线程上的 `applyGravity`
/// （`libvlc_video_set_aspect_ratio` 需要视频输出的锁）互相等待而死锁。
@MainActor
@Suite(.serialized)
struct VLCEngineTests {
    /// 回归：播放中关闭播放器（macOS 关窗口）会调用 `stop()`；曾因 `player.media = nil`
    /// 触发 VLCKit 4 内部 `libvlc_media_retain` 断言，整个进程中止。
    @Test func stopWhilePlayingDoesNotCrash() async throws {
        let url = try #require(Bundle.module.url(forResource: "embedded-subtitle", withExtension: "mkv", subdirectory: "Resources"))
        let engine = VLCPlaybackEngine()
        // libvlc 的 OpenGL 输出要求画面视图已在窗口中，否则在帧缓冲校验处断言。
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        engine.containerView.frame = window.contentView!.bounds
        window.contentView!.addSubview(engine.containerView)
        window.orderBack(nil)
        defer { window.close() }
        engine.setMuted(true)
        engine.load(PlaybackSource(url: url, title: "fixture"))
        for _ in 0..<50 where engine.status != .playing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(engine.status == .playing, "5 秒内未进入播放，状态 \(engine.status)")
        // 帧率按 1 秒窗口由 libvlc 统计折算，播放 1.5 秒后应可读到。
        try await Task.sleep(for: .milliseconds(1500))
        #expect(engine.currentFrameRate() != nil)
        engine.stop()
        // 让 libvlc 的异步事件（媒体切换回调）有机会在主线程派发。
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.status == .idle)
    }

    /// 回归：切换内核时从当前位置起播。曾用 `:start-time` 媒体选项，VLCKit 4.0.0a19 下 `time` 读数变成相对起播点
    /// （从 0 开始），切到 VLC 后进度从头开始、再切走时新内核也从错误位置起播。
    @Test func startsFromRequestedPositionWithAbsoluteTime() async throws {
        let url = try #require(Bundle.module.url(forResource: "embedded-subtitle", withExtension: "mkv", subdirectory: "Resources"))
        let engine = VLCPlaybackEngine()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        engine.containerView.frame = window.contentView!.bounds
        window.contentView!.addSubview(engine.containerView)
        window.orderBack(nil)
        defer { window.close() }
        engine.setMuted(true)
        engine.load(PlaybackSource(url: url, title: "fixture", startTime: 5))
        for _ in 0..<50 where engine.status != .playing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(engine.status == .playing, "5 秒内未进入播放，状态 \(engine.status)")
        try await Task.sleep(for: .milliseconds(1000))
        // 片长约 10 秒：从 5 秒起播约 1 秒后应在 5～8 秒之间；若读数相对起播点会在 2 秒以内。
        #expect((4.5...8).contains(engine.currentTime), "当前位置 \(engine.currentTime)")
        engine.stop()
        try await Task.sleep(for: .milliseconds(500))
    }
}

struct VLCProgressTrackerTests {
    /// 回归：VLCKit 4 的时间每 500 ms 才刷新，4 Hz 轮询时相邻两次读数相同不应判为缓冲（iPhone 播放中加载圈反复闪现）。
    @Test func repeatedReadingWithinGraceIsStillAdvancing() {
        var tracker = VLCProgressTracker()
        let start = Date(timeIntervalSince1970: 0)
        tracker.record(10.0, at: start)
        tracker.record(10.5, at: start.addingTimeInterval(0.25))
        tracker.record(10.5, at: start.addingTimeInterval(0.5))
        #expect(tracker.isAdvancing(at: start.addingTimeInterval(0.5)))
    }

    @Test func stalledBeyondGraceIsNotAdvancing() {
        var tracker = VLCProgressTracker()
        let start = Date(timeIntervalSince1970: 0)
        tracker.record(10.0, at: start)
        tracker.record(10.5, at: start.addingTimeInterval(0.5))
        tracker.record(10.5, at: start.addingTimeInterval(2.5))
        #expect(!tracker.isAdvancing(at: start.addingTimeInterval(2.5)))
    }

    @Test func seekJumpAfterResetIsNotProgress() {
        var tracker = VLCProgressTracker()
        let start = Date(timeIntervalSince1970: 0)
        tracker.record(10.0, at: start)
        tracker.reset()
        tracker.record(300.0, at: start.addingTimeInterval(0.25))
        #expect(!tracker.isAdvancing(at: start.addingTimeInterval(0.25)))
    }
}

struct VLCRateMeterTests {
    @Test func computesThroughputAndFrameRatePerSecond() {
        var meter = VLCRateMeter()
        let start = Date(timeIntervalSince1970: 0)
        meter.record(readBytes: 0, displayedPictures: 0, at: start)
        // 不足 1 秒不结算。
        meter.record(readBytes: 500_000, displayedPictures: 12, at: start.addingTimeInterval(0.5))
        #expect(meter.throughput == nil)
        meter.record(readBytes: 1_000_000, displayedPictures: 24, at: start.addingTimeInterval(1))
        #expect(meter.throughput == 8_000_000)
        #expect(meter.frameRate == 24)
    }

    /// 缓冲区满时没有新数据：保留上一次测得的下载速度，而不是显示 0。
    @Test func keepsLastThroughputWhileBufferFull() {
        var meter = VLCRateMeter()
        let start = Date(timeIntervalSince1970: 0)
        meter.record(readBytes: 0, displayedPictures: 0, at: start)
        meter.record(readBytes: 1_000_000, displayedPictures: 24, at: start.addingTimeInterval(1))
        meter.record(readBytes: 1_000_000, displayedPictures: 48, at: start.addingTimeInterval(2))
        #expect(meter.throughput == 8_000_000)
        #expect(meter.frameRate == 24)
    }

    /// Int32 累计字节回绕成负数时丢弃该段，不产生负速率。
    @Test func ignoresCounterWraparound() {
        var meter = VLCRateMeter()
        let start = Date(timeIntervalSince1970: 0)
        meter.record(readBytes: Int32.max - 10, displayedPictures: 0, at: start)
        meter.record(readBytes: Int32.min + 10, displayedPictures: 24, at: start.addingTimeInterval(1))
        #expect(meter.throughput == nil)
        meter.record(readBytes: Int32.min + 1_000_010, displayedPictures: 48, at: start.addingTimeInterval(2))
        #expect(meter.throughput == 8_000_000)
    }
}
