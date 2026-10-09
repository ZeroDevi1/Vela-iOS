import CoreMotion
import simd

/// VR 转平面的陀螺仪视角：把设备背面朝向（相当于「从屏幕往里看」的视线）的水平 / 俯仰变化量回调给调用方，
/// 叠加到当前视角上，因此可与拖动同时使用，开启时不会跳到设备的绝对朝向。
///
/// 视线方向与界面横竖屏无关（只有画面的横滚会受影响，此处不处理横滚）。
/// `CMMotionManager` 仅 iOS 可用：macOS 与没有陀螺仪的设备（模拟器）上 `isAvailable` 为 false，`start` 不做任何事。
@MainActor
public final class VRMotionTracker {
    #if os(iOS)
    private let manager = CMMotionManager()
    #endif
    /// 上一次的视线水平角与俯仰角（度）；nil 表示尚无基准（刚开始或视线接近竖直）。
    private var lastHeading: Double?
    private var lastPitch: Double?

    /// 视线接近竖直（俯仰超过该值，度）时水平角不稳定，暂停水平转动，避免画面突然甩动。
    private static let headingPitchLimit: Double = 80

    public init() {}

    /// 设备是否有可用的陀螺仪姿态数据；菜单据此决定是否显示开关。
    #if os(iOS)
    public static let isAvailable = CMMotionManager().isDeviceMotionAvailable
    public var isRunning: Bool { manager.isDeviceMotionActive }
    #else
    public static let isAvailable = false
    public var isRunning: Bool { false }
    #endif

    /// 开始跟踪；`onRotate` 收到角度增量（度，正值向右 / 向上），在主线程调用。
    public func start(onRotate: @escaping @MainActor (_ yaw: Double, _ pitch: Double) -> Void) {
        #if os(iOS)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lastHeading = nil
        lastPitch = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let q = motion.attitude.quaternion
            let attitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            MainActor.assumeIsolated { self?.handle(attitude, onRotate: onRotate) }
        }
        #endif
    }

    public func stop() {
        #if os(iOS)
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        #endif
    }

    private func handle(_ q: simd_quatd, onRotate: @MainActor (Double, Double) -> Void) {
        let (heading, pitch) = Self.orientation(of: q)
        let deltaPitch = lastPitch.map { pitch - $0 } ?? 0
        var deltaYaw = 0.0
        if abs(pitch) < Self.headingPitchLimit, let heading {
            if let lastHeading { deltaYaw = Self.wrap(heading - lastHeading) }
            lastHeading = heading
        } else {
            lastHeading = nil
        }
        lastPitch = pitch
        guard deltaYaw != 0 || deltaPitch != 0 else { return }
        onRotate(deltaYaw, deltaPitch)
    }

    /// 设备姿态 → 视线（设备 -Z，屏幕背面）的水平角与俯仰角（度）。参考系 Z 轴竖直向上；水平角顺时针（向右转）为正。
    /// 视线接近竖直时水平角无意义，返回 nil。
    nonisolated static func orientation(of attitude: simd_quatd) -> (heading: Double?, pitch: Double) {
        let look = attitude.act(SIMD3<Double>(0, 0, -1))
        let pitch = asin(min(max(look.z, -1), 1)) * 180 / .pi
        let horizontal = simd_length(SIMD2(look.x, look.y))
        let heading = horizontal > 1e-3 ? -atan2(look.y, look.x) * 180 / .pi : nil
        return (heading, pitch)
    }

    /// 角度差折回 -180...180，跨过 ±180° 时不产生整圈跳变。
    nonisolated static func wrap(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}
