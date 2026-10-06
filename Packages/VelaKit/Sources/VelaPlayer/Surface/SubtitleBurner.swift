import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation

/// 把字幕文字画进视频帧，供画中画使用。
///
/// 画中画窗口只显示视频图层的内容，播放页上叠加的 SwiftUI 字幕不会进入小窗，因此在送往画中画的每一帧上直接叠加字幕。
/// 输出缩小到最宽 1280（小窗用不到更高分辨率），并转为 SDR BGRA：HDR 高光会被裁剪，小窗中可以接受，换来更低的功耗。
///
/// 线程：`setText` 在主线程调用，`burn` 在出帧线程调用，内部用锁保护文字与缓存。
final class SubtitleBurner: @unchecked Sendable {
    static let maxOutputWidth = 1280

    private let lock = NSLock()
    private var text: String?
    /// 上次渲染的字幕图像（文字或尺寸不变时复用，字幕通常持续数秒）。
    private var overlayCache: (text: String, width: Int, height: Int, image: CIImage)?
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int, format: OSType) = (0, 0, 0)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 字号相对输出高度的比例，与播放页默认字号在小窗中的观感接近。
    var relativeFontSize: CGFloat = 0.058

    func setText(_ text: String?) {
        lock.withLock { self.text = text?.isEmpty == true ? nil : text }
    }

    var hasText: Bool {
        lock.withLock { text != nil }
    }

    /// 返回叠加了字幕、像素格式 / 尺寸 / 色彩空间都与原帧相同的新帧；当前没有字幕时返回 nil，调用方直接使用原帧。
    ///
    /// 用于 KSPlayer：它在帧格式变化时会重建显示图层，而画中画绑定在该图层上，因此不能改变格式或缩小。
    /// 色彩空间沿用原帧，HDR 片源仍以 HDR 显示。
    func burnPreservingFormat(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let text = lock.withLock({ text }) else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0,
              let output = makeBuffer(width: width, height: height, format: CVPixelBufferGetPixelFormatType(source)),
              let overlay = overlay(for: text, width: width, height: height) else { return nil }
        CVBufferPropagateAttachments(source, output)
        let colorSpace = CVImageBufferGetColorSpace(source)?.takeUnretainedValue() ?? outputColorSpace
        let image = overlay.composited(over: CIImage(cvPixelBuffer: source))
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        return output
    }

    /// 无论有无字幕都输出缩小后的 SDR 帧（系统内核的画中画内容源需要连续的帧）。
    func render(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        render(source, text: lock.withLock { text })
    }

    private func render(_ source: CVPixelBuffer, text: String?) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(1, Double(Self.maxOutputWidth) / Double(sourceWidth))
        let width = max(2, Int((Double(sourceWidth) * scale).rounded()) & ~1)
        let height = max(2, Int((Double(sourceHeight) * scale).rounded()) & ~1)
        guard let output = makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) else { return nil }
        // 标明为 SDR（BT.709 原色 + sRGB 传递函数），否则显示层可能按原片的 HDR 元数据解释。
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)

        var image = CIImage(cvPixelBuffer: source)
        if width != sourceWidth || height != sourceHeight {
            image = image.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(sourceWidth),
                y: CGFloat(height) / CGFloat(sourceHeight)
            ))
        }
        if let text, let overlay = overlay(for: text, width: width, height: height) {
            image = overlay.composited(over: image)
        }
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: outputColorSpace)
        return output
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if pool == nil || poolSize != (width, height, format) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height, format)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// 白字黑边、底部居中的字幕图像（CoreImage 坐标原点在左下）。
    private func overlay(for text: String, width: Int, height: Int) -> CIImage? {
        if let cache = lock.withLock({ overlayCache }), cache.text == text, cache.width == width, cache.height == height {
            return cache.image
        }
        let fontSize = max(12, CGFloat(height) * relativeFontSize)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        func attributed(fill: CGColor, strokeWidth: CGFloat) -> CFAttributedString {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: fill,
                kCTStrokeColorAttributeName: CGColor(gray: 0, alpha: 0.9),
                kCTStrokeWidthAttributeName: strokeWidth,
                kCTParagraphStyleAttributeName: paragraph
            ]
            return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        }
        // 先画描边（正值 = 只描边），再画填充，得到不压缩字形的黑边白字。
        let stroke = CTFramesetterCreateWithAttributedString(attributed(fill: CGColor(gray: 0, alpha: 0.9), strokeWidth: 12))
        let fill = CTFramesetterCreateWithAttributedString(attributed(fill: CGColor(gray: 1, alpha: 1), strokeWidth: 0))

        let maxTextWidth = CGFloat(width) * 0.9
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            fill, CFRange(), nil, CGSize(width: maxTextWidth, height: CGFloat(height) / 2), nil
        )
        let padding = ceil(fontSize * 0.25)
        let canvasWidth = Int(ceil(maxTextWidth + padding * 2))
        let canvasHeight = Int(ceil(fitted.height + padding * 2))
        guard canvasHeight > 0, let context = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: outputColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: maxTextWidth, height: fitted.height), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(stroke, CFRange(), path, nil), context)
        CTFrameDraw(CTFramesetterCreateFrame(fill, CFRange(), path, nil), context)
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(
            translationX: (CGFloat(width) - CGFloat(canvasWidth)) / 2,
            y: CGFloat(height) * 0.05
        ))
        lock.withLock { overlayCache = (text, width, height, image) }
        return image
    }
}
