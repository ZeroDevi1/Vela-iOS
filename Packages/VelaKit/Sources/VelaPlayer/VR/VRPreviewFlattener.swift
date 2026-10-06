import CoreGraphics
import Foundation

/// 拖动预览帧的 VR 转平面：把预览缩略图按当前视角反投影成与主画面一致的平面画面。
///
/// 只处理单张小图（约 480 像素宽、仅在拖动时产生），在 CPU 上用与着色器相同的公式（`VRProjection`）逐像素取样，
/// 每张耗时毫秒级；不走 Metal，避免为偶发的静态图创建离屏渲染管线。
/// 预览源本身分辨率低（整幅全景约 480 像素宽），转平面后只取其中一部分，画面会比主画面模糊。
public enum VRPreviewFlattener {
    /// - Parameter outputSize: 输出像素尺寸，宽高比应与预览框一致。
    public static func flatten(_ image: CGImage, layout: VRLayout, view: VRViewState, outputSize: CGSize) -> CGImage? {
        let srcWidth = image.width, srcHeight = image.height
        let outWidth = Int(outputSize.width.rounded()), outHeight = Int(outputSize.height.rounded())
        guard srcWidth > 1, srcHeight > 1, outWidth > 0, outHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var source = [UInt8](repeating: 0, count: srcWidth * srcHeight * 4)
        let drawn = source.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: srcWidth, height: srcHeight, bitsPerComponent: 8,
                bytesPerRow: srcWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: srcWidth, height: srcHeight))
            return true
        }
        guard drawn else { return nil }

        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let aspect = Double(outWidth) / Double(outHeight)
        let maxX = Double(srcWidth - 1), maxY = Double(srcHeight - 1)
        for y in 0..<outHeight {
            // NDC 的 y 向上，位图行从上往下。
            let ndcY = 1 - (Double(y) + 0.5) / Double(outHeight) * 2
            for x in 0..<outWidth {
                let ndcX = (Double(x) + 0.5) / Double(outWidth) * 2 - 1
                let target = (y * outWidth + x) * 4
                output[target + 3] = 255
                guard let uv = VRProjection.sourceUV(ndc: SIMD2(ndcX, ndcY), aspect: aspect, view: view, layout: layout) else { continue }
                // 双线性取样。
                let fx = uv.x * maxX, fy = uv.y * maxY
                let x0 = Int(fx), y0 = Int(fy)
                let x1 = min(x0 + 1, srcWidth - 1), y1 = min(y0 + 1, srcHeight - 1)
                let tx = fx - Double(x0), ty = fy - Double(y0)
                for channel in 0..<3 {
                    let a = Double(source[(y0 * srcWidth + x0) * 4 + channel])
                    let b = Double(source[(y0 * srcWidth + x1) * 4 + channel])
                    let c = Double(source[(y1 * srcWidth + x0) * 4 + channel])
                    let d = Double(source[(y1 * srcWidth + x1) * 4 + channel])
                    let top = a + (b - a) * tx, bottom = c + (d - c) * tx
                    output[target + channel] = UInt8(min(255, max(0, (top + (bottom - top) * ty).rounded())))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(
            width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outWidth * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
