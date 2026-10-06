import Foundation
import simd

/// VR 反投影的视角状态与数学。与 Metal 着色器（`VRRenderer.shaderSource`）及 Android 版 `vr_flatten.glsl` 使用同一套公式；
/// Swift 版用于单测与边界计算，渲染只走 GPU。
public struct VRViewState: Hashable, Sendable {
    /// 水平转角（度），正值向右看。
    public var yaw: Double = 0
    /// 俯仰角（度），正值向上看。
    public var pitch: Double = 0
    /// 输出视场角（度，沿画面长边）。
    public var outputFOV: Double = VRViewport.defaultOutputFOV

    public init(yaw: Double = 0, pitch: Double = 0, outputFOV: Double = VRViewport.defaultOutputFOV) {
        self.yaw = yaw
        self.pitch = pitch
        self.outputFOV = outputFOV
    }

    /// 拖动：按视场角换算像素到角度，拖动距离等于屏幕长边时转过一个视场角。
    public mutating func drag(by translation: CGSize, viewSize: CGSize, layout: VRLayout) {
        let longSide = max(viewSize.width, viewSize.height, 1)
        let degreesPerPoint = outputFOV / longSide
        // 手指向右拖，画面跟手向右移，相当于视线向左转。
        yaw = clamp(yaw - translation.width * degreesPerPoint, layout.yawLimit)
        pitch = clamp(pitch + translation.height * degreesPerPoint, 90)
    }

    /// 捏合：scale > 1 放大（视场角变小）。
    public mutating func zoom(by scale: Double) {
        guard scale > 0 else { return }
        outputFOV = min(max(outputFOV / scale, VRViewport.minOutputFOV), VRViewport.maxOutputFOV)
    }

    private func clamp(_ value: Double, _ limit: Double) -> Double {
        // 360° 全景水平方向循环，不设边界。
        if limit >= 180 {
            var wrapped = value.truncatingRemainder(dividingBy: 360)
            if wrapped > 180 { wrapped -= 360 }
            if wrapped < -180 { wrapped += 360 }
            return wrapped
        }
        return min(max(value, -limit), limit)
    }
}

public enum VRProjection {
    /// 输出画面上一点（NDC，x / y 均为 -1...1，y 向上）对应的源纹理坐标（0...1，y 向下）；落在源画面外时返回 nil。
    public static func sourceUV(ndc: SIMD2<Double>, aspect: Double, view: VRViewState, layout: VRLayout) -> SIMD2<Double>? {
        var point = ndc
        point.x *= aspect
        // 视场角沿长边：竖屏时按高度计算，宽屏时按宽度计算。
        let tanHalf = tan(radians(view.outputFOV) / 2) / max(aspect, 1)
        let dir = normalize(SIMD3(point.x * tanHalf, point.y * tanHalf, 1))

        let cy = cos(radians(view.yaw)), sy = sin(radians(view.yaw))
        let cp = cos(radians(view.pitch)), sp = sin(radians(view.pitch))
        let pitched = SIMD3(dir.x, dir.y * cp + dir.z * sp, -dir.y * sp + dir.z * cp)
        let look = SIMD3(pitched.x * cy + pitched.z * sy, pitched.y, -pitched.x * sy + pitched.z * cy)

        var uv: SIMD2<Double>
        switch layout.projection {
        case .fisheye:
            let theta = acos(min(max(look.z, -1), 1))
            let r = theta / radians(Double(layout.inputFOV))
            let mag = simd_length(SIMD2(look.x, look.y))
            let n = mag > 1e-6 ? SIMD2(look.x, look.y) / mag : .zero
            uv = n * r + SIMD2(0.5, 0.5)
            uv.y = 1 - uv.y
        case .halfEquirect, .equirect:
            let sourceFOV = layout.projection == .equirect ? 360.0 : max(Double(layout.inputFOV), 1)
            let lon = atan2(look.x, look.z)
            let lat = asin(min(max(look.y, -1), 1))
            uv = SIMD2(lon / radians(sourceFOV) + 0.5, 0.5 - lat / .pi)
        }
        guard (0...1).contains(uv.x), (0...1).contains(uv.y) else { return nil }
        // 立体片源只取左眼（左半 / 上半）。
        switch layout.stereo {
        case .sideBySide: uv.x *= 0.5
        case .topBottom: uv.y *= 0.5
        case .mono: break
        }
        return uv
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
