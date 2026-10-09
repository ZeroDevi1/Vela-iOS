import Foundation
import Network
import Observation

/// 设备网络状态（`NWPathMonitor`）。无网络时界面回退到已下载内容（与 Android 版一致），
/// 预告片自动播放等只在非蜂窝、非低数据模式下进行。
@MainActor
@Observable
public final class NetworkStatus {
    /// 有可用网络路径；启动时先假定在线，避免首次回调前误显示离线界面。
    public private(set) var isOnline = true
    /// 当前路径为蜂窝网络、个人热点等按流量计费的连接（`isExpensive`），或开启了低数据模式（`isConstrained`）。
    public private(set) var isMetered = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isMetered != metered { self.isMetered = metered }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.vela.network-status"))
    }

    deinit {
        monitor.cancel()
    }
}
