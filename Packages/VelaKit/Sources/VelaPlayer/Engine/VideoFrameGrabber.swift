import AVFoundation
import CoreImage
import Foundation

/// 从 `AVPlayerItem` 读取解码后的画面。只在需要时挂载 `AVPlayerItemVideoOutput`，用完即移除，
/// 避免常驻输出给 HDR / 杜比视界播放增加额外的像素格式转换。
@MainActor
enum VideoFrameGrabber {
    /// 输出为 8 位 BGRA：截图与预览只需 SDR 画面，HDR 内容会被系统色调映射。
    private static let attributes = CVPixelBufferAttributes(pixelFormatTypes: [CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA)])
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 挂载输出并等待一帧。
    /// - Parameters:
    ///   - nudge: 输出挂载后若迟迟没有新帧（通常是暂停中），调用一次以促使内核重新送帧，例如原地 seek。
    ///   - timeout: 最长等待时间；超时返回 nil。
    static func grab(
        from item: AVPlayerItem,
        maxPixelWidth: CGFloat? = nil,
        timeout: Duration = .seconds(2),
        nudge: (() async -> Void)? = nil
    ) async -> CGImage? {
        await grabSample(from: item, maxPixelWidth: maxPixelWidth, timeout: timeout, nudge: nudge)?.image
    }

    static func grabSample(
        from item: AVPlayerItem,
        maxPixelWidth: CGFloat? = nil,
        timeout: Duration,
        nudge: (() async -> Void)? = nil,
        prepare: (() async -> Bool)? = nil
    ) async -> ScrubPreviewFrameSample? {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        defer { item.remove(output) }
        if let prepare {
            guard await prepare(), !Task.isCancelled else { return nil }
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var nudged = false
        while clock.now < deadline, !Task.isCancelled {
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time) {
                let sample = output.pixelBufferAndDisplayTime(forItemTime: time)
                if let buffer = sample.pixelBuffer,
                   let frame = buffer.withUnsafeBuffer({ image(from: $0, maxPixelWidth: maxPixelWidth) }) {
                    if sample.itemTimeForDisplay.isNumeric {
                        return ScrubPreviewFrameSample(image: frame, time: sample.itemTimeForDisplay.seconds)
                    }
                    if prepare == nil { return ScrubPreviewFrameSample(image: frame, time: time.seconds) }
                }
            }
            if !nudged, clock.now > deadline - timeout * 0.8, let nudge {
                nudged = true
                await nudge()
            }
            try? await Task.sleep(for: .milliseconds(30))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    static func image(from buffer: CVPixelBuffer, maxPixelWidth: CGFloat?) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if let maxPixelWidth, image.extent.width > maxPixelWidth {
            let scale = maxPixelWidth / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.createCGImage(image, from: image.extent.integral)
    }
}
