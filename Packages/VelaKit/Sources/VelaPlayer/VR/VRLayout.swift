import Foundation

/// VR 片源排布。「VR 转平面」把 180 / 360 / 鱼眼画面按视角反投影成普通 2D 画面（取左眼），而非头显双目输出。
public struct VRLayout: Hashable, Sendable, Codable {
    public enum Projection: String, Sendable, Codable, CaseIterable {
        /// 180° 等距柱状。
        case halfEquirect
        /// 360° 等距柱状。
        case equirect
        case fisheye
    }

    public enum Stereo: String, Sendable, Codable, CaseIterable {
        case sideBySide
        case topBottom
        case mono
    }

    public var projection: Projection
    public var stereo: Stereo
    /// 源画面视场角（度）：180 / 360，鱼眼为 190 / 200 / 220。
    public var inputFOV: Int

    public init(projection: Projection, stereo: Stereo, inputFOV: Int) {
        self.projection = projection
        self.stereo = stereo
        self.inputFOV = inputFOV
    }

    /// 菜单中的名称，例如「180° 左右」「鱼眼 200° 左右」。
    public var displayName: String {
        let stereoName = switch stereo {
        case .sideBySide: "左右"
        case .topBottom: "上下"
        case .mono: "单眼"
        }
        switch projection {
        case .halfEquirect: return "180° \(stereoName)"
        case .equirect: return "360° \(stereoName)"
        case .fisheye: return "鱼眼 \(inputFOV)° \(stereoName)"
        }
    }

    /// 视角水平转动的上限（度）。
    public var yawLimit: Double { projection == .equirect ? 180 : 90 }
}

/// 输出视场角参数（度，沿画面长边）。默认 100° 接近头显观感；捏合在最小（拉近）与最大（看全景）之间调整。
public enum VRViewport {
    public static let defaultOutputFOV: Double = 100
    public static let minOutputFOV: Double = 50
    public static let maxOutputFOV: Double = 150
}
