import CoreGraphics
import Foundation

/// 由海报平均色推出详情页背景的深色调（Forward 风格：取海报主色的低饱和深色渐变）。
///
/// 平均色直接当背景太亮、太艳，会压过白色文字；这里只保留色相，饱和度封顶、亮度压到固定的暗区间，
/// 保证任何海报下白字都清晰。接近灰色的海报（饱和度极低）不强行上色，返回 nil，由调用方回退到纯黑背景。
public enum BackdropTone {
    /// 色相 0–1，饱和度 0–1，亮度 0–1。
    public struct HSB: Equatable, Sendable {
        public var hue: Double
        public var saturation: Double
        public var brightness: Double
    }

    /// 背景渐变顶部的颜色亮度；底部由界面再压暗。
    static let brightness = 0.28
    static let maxSaturation = 0.5
    /// 平均色饱和度低于此值视为灰色海报。
    static let grayThreshold = 0.08

    /// 在 sRGB 中将图片缩到 1 像素，再用平均色计算背景色调。
    public static func darkTone(for image: CGImage) -> HSB? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return darkTone(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }

    /// - Parameters: 平均色的 sRGB 分量（0–1）。
    public static func darkTone(red: Double, green: Double, blue: Double) -> HSB? {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        guard maxValue > 0, delta / maxValue >= grayThreshold else { return nil }
        let hue: Double
        switch maxValue {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        case green: hue = ((blue - red) / delta + 2) / 6
        default: hue = ((red - green) / delta + 4) / 6
        }
        return HSB(
            hue: hue < 0 ? hue + 1 : hue,
            saturation: min(delta / maxValue, maxSaturation),
            brightness: brightness
        )
    }
}
