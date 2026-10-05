#if os(iOS)
import UIKit
import VelaCore
import VelaData
import VelaPlayer

/// 播放器横竖屏切换（iPhone）。
///
/// 只调用 `requestGeometryUpdate` 时，系统会随设备朝向立刻转回去；因此同时收窄应用支持的方向（经
/// `VelaAppDelegate` 返回 `supportedMask`），把界面锁定在所选方向。关闭播放器时调用 `unlock()` 恢复。
@MainActor
public enum OrientationController {
    /// 默认允许的方向，与 Info.plist 中 iPhone 的设置一致（不含倒置竖屏）。
    static let defaultMask: UIInterfaceOrientationMask = .allButUpsideDown

    /// 当前允许的方向，由 `VelaAppDelegate` 返回给系统。
    public private(set) static var supportedMask: UIInterfaceOrientationMask = defaultMask

    /// 只有 iPhone 支持切换：iPad 分屏 / 台前调度下窗口方向不受应用控制。
    static var isSupported: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// 当前前台的窗口场景。
    static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// 强制横屏时使用的方向（「设备横屏方向」设置）。
    static var landscapeSide: LandscapeSide = .auto

    private static var landscapeMask: UIInterfaceOrientationMask {
        switch landscapeSide {
        case .auto: .landscape
        case .left: .landscapeLeft
        case .right: .landscapeRight
        }
    }

    /// 在横屏与竖屏之间切换并锁定。
    static func toggle(in scene: UIWindowScene? = activeScene) {
        guard isSupported, let scene else { return }
        let isLandscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        if isLandscape {
            lock(.portrait, preferred: .portrait, in: scene)
        } else {
            lock(landscapeMask, preferred: landscapeSide == .left ? .landscapeLeft : .landscapeRight, in: scene)
        }
    }

    /// 按「进入播放器 / 切换视频后屏幕方向」设置调整方向。`videoSize` 未知时「跟随视频」不做处理。
    static func apply(_ orientation: PlayerOrientation, videoSize: CGSize, in scene: UIWindowScene? = activeScene) {
        guard isSupported, let scene else { return }
        let wantsLandscape: Bool
        switch orientation {
        case .unchanged: return
        case .landscape: wantsLandscape = true
        case .portrait: wantsLandscape = false
        case .followVideo:
            guard videoSize.width > 0, videoSize.height > 0 else { return }
            wantsLandscape = videoSize.width >= videoSize.height
        }
        if wantsLandscape {
            lock(landscapeMask, preferred: landscapeSide == .left ? .landscapeLeft : .landscapeRight, in: scene)
        } else {
            lock(.portrait, preferred: .portrait, in: scene)
        }
    }

    /// 解除锁定；若当前为强制横屏则回到竖屏。
    static func unlock(in scene: UIWindowScene? = activeScene) {
        guard isSupported, supportedMask != defaultMask else { return }
        let wasLandscapeLock = !supportedMask.contains(.portrait)
        supportedMask = defaultMask
        guard let scene else { return }
        refresh(scene)
        if wasLandscapeLock {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }

    private static func lock(_ mask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        supportedMask = mask
        refresh(scene)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred)) { error in
            Log.app.error("横竖屏切换失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 通知所有窗口的根控制器重新读取支持的方向（全屏播放器在独立的呈现控制器中）。
    private static func refresh(_ scene: UIWindowScene) {
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }
}

/// App 代理：返回当前允许的方向（播放器横竖屏锁定），并接收后台下载完成事件。
public final class VelaAppDelegate: NSObject, UIApplicationDelegate {
    public func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationController.supportedMask }
    }

    /// 后台下载完成时系统唤醒应用：保存回调，等会话事件处理完再调用。
    public func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { DownloadManager.handleBackgroundEvents(identifier: identifier, completion: completionHandler) }
    }
}
#endif
