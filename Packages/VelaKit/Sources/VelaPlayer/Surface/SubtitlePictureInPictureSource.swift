import AVFoundation
import AVKit
import CoreMedia
import QuartzCore

/// 系统内核（AVPlayer）带字幕的画中画内容源。
///
/// `AVPictureInPictureController(playerLayer:)` 只显示 AVPlayerLayer 的视频，无法加入字幕。有字幕时改用
/// 样本缓冲区内容源：从 `AVPlayerItemVideoOutput` 取帧，缩小并叠加字幕（`SubtitleBurner`）后送入自有的
/// `AVSampleBufferDisplayLayer`；播放 / 暂停 / 快进快退由 `AVPictureInPictureSampleBufferPlaybackDelegate` 转给播放器。
///
/// 只在画中画期间出帧（约 30 帧 / 秒，后台计时器驱动），平时图层为空、不消耗解码拷贝之外的资源。
/// 画中画期间 AVPlayer 从 AVPlayerLayer 上摘下：仍挂在图层上的播放器切到后台会被系统暂停。
@MainActor
final class SubtitlePictureInPictureSource: NSObject {
    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var pictureInPicture: AVPictureInPictureController?
    private let burner: SubtitleBurner
    private weak var controller: PlayerController?
    private let pump: FramePump
    private var itemObservation: NSKeyValueObservation?
    private var possibleObservation: NSKeyValueObservation?
    /// 能否进入画中画的状态变化（宿主据此决定由谁负责「切后台自动画中画」）。
    var onPossibleChange: (() -> Void)?

    var isPossible: Bool { pictureInPicture?.isPictureInPicturePossible == true }

    init(player: AVPlayer, controller: PlayerController, burner: SubtitleBurner) {
        self.controller = controller
        self.burner = burner
        pump = FramePump(layer: displayLayer, burner: burner)
        super.init()
        displayLayer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        pictureInPicture = AVPictureInPictureController(contentSource: source)
        possibleObservation = pictureInPicture?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onPossibleChange?() }
        }
        setPlayer(player)
    }

    /// 换码流或接管跳转预热的播放器时，将输出挂到实际播放的条目。
    func setPlayer(_ player: AVPlayer) {
        itemObservation = nil
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            MainActor.assumeIsolated { self?.pump.attach(to: item) }
        }
    }

    /// 开始画中画：先把一帧送进图层再启动。图层里还没有帧时视频尺寸为 0，macOS 的画中画宿主视图按 0/0 的宽高比
    /// 计算出 NaN 坐标，AppKit 断言「Invalid view geometry: x is NaN」直接中止进程（iOS 不崩溃，但小窗没有画面）。
    /// 取不到帧（尚未起播）时返回 false，由调用方改用原生画中画。
    func start() -> Bool {
        guard pump.renderNow() else { return false }
        pictureInPicture?.startPictureInPicture()
        return true
    }

    func didStart() {
        pump.start(framesPerSecond: 30)
    }

    func didStop() {
        pump.stop()
        pump.clearDisplayedImage()
    }

    func invalidate() {
        itemObservation = nil
        possibleObservation = nil
        onPossibleChange = nil
        pump.stop()
        pump.attach(to: nil)
        pictureInPicture?.stopPictureInPicture()
    }

    /// 播放 / 暂停状态变化后让小窗刷新按钮状态。
    func invalidatePlaybackState() {
        pictureInPicture?.invalidatePlaybackState()
    }
}

extension SubtitlePictureInPictureSource: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            guard let engine = controller?.engine else { return }
            playing ? engine.play() : engine.pause()
            invalidatePlaybackState()
        }
    }

    /// 时间范围以宿主时钟表示（图层的时间基准由 `FramePump` 的同步器驱动，与宿主时钟一致）：起点 = 现在 - 当前位置，小窗据此显示进度。
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            guard let engine = controller?.engine, engine.duration > 0 else {
                return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let start = CMTimeSubtract(now, CMTime(seconds: engine.currentTime, preferredTimescale: 600))
            return CMTimeRange(start: start, duration: CMTime(seconds: engine.duration, preferredTimescale: 600))
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { controller?.isPlaying != true }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        await MainActor.run {
            guard let engine = controller?.engine else { return }
            let target = engine.currentTime + skipInterval.seconds
            Task { await engine.seek(to: target) }
        }
    }
}

/// 在后台队列按固定频率取帧、叠字幕并送入显示图层。画中画时应用处于后台，主线程的显示刷新回调不可靠，因此用计时器驱动。
///
/// iOS / macOS 27 起渲染器自身的入队接口弃用，改为挂到 `AVSampleBufferRenderSynchronizer` 上经 `Receiver` 入队。
/// 同步器只用作时间基准：速率 1、时间与宿主时钟对齐，样本时间戳取宿主时钟当前值并标记立即显示，
/// 因此显示时机与迁移前（图层无时间基准、帧到即显示）相同，画中画的时间范围仍按宿主时钟计算。
private final class FramePump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vela.pip.subtitle-frames", qos: .userInteractive)
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    /// 显示图层渲染器的入队端。在主线程取得后由出帧队列使用。
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private let burner: SubtitleBurner
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private var item: AVPlayerItem?
    private var timer: DispatchSourceTimer?

    @MainActor
    init(layer: AVSampleBufferDisplayLayer, burner: SubtitleBurner) {
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
        self.burner = burner
    }

    /// 清除小窗最后一帧（画中画结束后调用）。在出帧队列上执行，避免与正在进行的入队交错。
    func clearDisplayedImage() {
        queue.async { [self] in
            Task { await self.receiver.flush(removingDisplayedImage: true) }
        }
    }

    func attach(to newItem: AVPlayerItem?) {
        lock.lock()
        defer { lock.unlock() }
        guard newItem !== item else { return }
        if let item, let output { item.remove(output) }
        item = newItem
        output = nil
        guard let newItem else { return }
        // 输出原生解码格式（不指定像素格式），由 SubtitleBurner 统一转换为 SDR BGRA。
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        newItem.add(output)
        self.output = output
    }

    func start(framesPerSecond: Int) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / framesPerSecond), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.tick(force: false) }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    /// 在出帧队列上同步送一帧（开始画中画前调用），返回是否送入成功。
    func renderNow() -> Bool {
        queue.sync { tick(force: true) }
    }

    /// - Parameter force: 即使没有新帧也重新取当前帧（开始画中画时先送一帧）。
    /// - Returns: 是否送入了一帧。
    @discardableResult
    private func tick(force: Bool) -> Bool {
        guard let output = lock.withLock({ output }) else { return false }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        // 暂停时没有新帧，小窗保持上一帧。
        guard force || output.hasNewPixelBuffer(forItemTime: itemTime),
              let frame = output.pixelBufferAndDisplayTime(forItemTime: itemTime).pixelBuffer else { return false }
        // 只读取像素生成新帧，不修改原缓冲区（与 VR 渲染器取帧方式相同）。
        var rendered: CVPixelBuffer?
        frame.withUnsafeBuffer { rendered = burner.render($0) }
        guard let rendered, let sample = Self.makeSampleBuffer(rendered) else { return false }
        switch receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample)) {
        case .enqueued, .enqueuedWithDecodeFailures:
            return true
        case .cancelledDueToFlush:
            return false
        case .cancelledDueToFlushRequiredToResume, .cancelledDueToError:
            // 渲染器进入失败 / 需要 flush 的状态（如应用切后台时解码会话失效）：flush 后下一次取帧重新入队。
            receiver.flush()
            return false
        @unknown default:
            return false
        }
    }

    /// 立即显示的样本：时间戳取宿主时钟当前值（与同步器时间一致），并标记立即显示。
    private static func makeSampleBuffer(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}
