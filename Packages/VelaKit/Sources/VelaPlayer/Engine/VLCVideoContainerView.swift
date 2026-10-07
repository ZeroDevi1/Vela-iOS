import Foundation
import os
@preconcurrency import VLCKit

/// 交给 libvlc 的绘制目标（画面容器视图），同时桥接 VLCKit 4 的画中画协议。
///
/// libvlc 的视频输出只有在绘制目标实现 `VLCPictureInPictureDrawable` 时才创建画中画控制器，
/// 并在就绪后通过 `pictureInPictureReady` 交回窗口控制对象。必须是视图本身而不是独立对象：
/// macOS 的视频窗口模块会把绘制目标当 `NSView` 调用 `frame` 等方法。
///
/// 线程：画中画方法由 libvlc / AVKit 在任意线程调用。查询类方法读取引擎轮询时写入的快照（加锁），
/// 不同步回主线程，避免视频输出线程持锁等待主线程造成死锁；控制类方法异步转到主线程。
final class VLCVideoContainerView: PlayerPlatformView, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling {
    /// 画中画查询用的播放状态快照；时间单位毫秒。
    struct Snapshot: Sendable {
        var timeMs: Int64 = 0
        var lengthMs: Int64 = 0
        var isPlaying = false
        var isSeekable = false
    }

    /// 引擎注入的控制回调，均在主线程调用。
    struct Handlers {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        /// 偏移量单位毫秒。
        var seekBy: @MainActor (Int64) async -> Void
        /// 画中画窗口控制对象就绪。
        var ready: @MainActor (any VLCPictureInPictureWindowControlling) -> Void
    }

    var handlers: Handlers?
    private nonisolated let snapshotLock = OSAllocatedUnfairLock(initialState: Snapshot())

    func update(_ snapshot: Snapshot) {
        snapshotLock.withLock { $0 = snapshot }
    }

    private nonisolated var snapshot: Snapshot { snapshotLock.withLock { $0 } }

    // MARK: VLCPictureInPictureDrawable

    nonisolated func mediaController() -> (any VLCPictureInPictureMediaControlling)! { self }

    nonisolated func pictureInPictureReady() -> ((any VLCPictureInPictureWindowControlling)?) -> Void {
        { [weak self] controller in
            guard let controller else { return }
            nonisolated(unsafe) let windowController = controller
            Self.onMain { self?.handlers?.ready(windowController) }
        }
    }

    // MARK: VLCPictureInPictureMediaControlling

    nonisolated func play() {
        Self.onMain { [weak self] in self?.handlers?.play() }
    }

    nonisolated func pause() {
        Self.onMain { [weak self] in self?.handlers?.pause() }
    }

    nonisolated func seek(by offset: Int64, completion: @escaping () -> Void) {
        nonisolated(unsafe) let completion = completion
        Self.onMain { [weak self] in
            guard let seek = self?.handlers?.seekBy else { return completion() }
            Task { @MainActor in
                await seek(offset)
                completion()
            }
        }
    }

    nonisolated func mediaLength() -> Int64 { snapshot.lengthMs }
    nonisolated func mediaTime() -> Int64 { snapshot.timeMs }
    nonisolated func isMediaSeekable() -> Bool { snapshot.isSeekable }
    nonisolated func isMediaPlaying() -> Bool { snapshot.isPlaying }

    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            nonisolated(unsafe) let work = work
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }
}
