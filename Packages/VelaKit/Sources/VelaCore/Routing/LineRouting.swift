import Foundation

/// 当前网络对线路选择的意义。
public enum NetworkAccess: Sendable {
    case offline
    /// Wi-Fi / 有线：局域网线路可能可达，优先尝试。
    case lanCapable
    /// 蜂窝等只能走公网的网络。
    case wan
}

/// 多线路路由的纯逻辑部分；网络探测与切换时机由 VelaData 中的路由器负责。
public enum LineRouting {
    /// 判断主机是否属于私有 / 本地网络（RFC 1918、localhost、mDNS `.local`、`.lan`）。
    public static func isLANHost(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return false }
        if value == "localhost" || value == "::1" || value == "0:0:0:0:0:0:0:1" { return true }
        if value.hasSuffix(".local") || value.hasSuffix(".lan") { return true }
        if value.hasPrefix("192.168.") || value.hasPrefix("10.") { return true }
        if value.hasPrefix("172.") {
            let parts = value.split(separator: ".")
            guard parts.count > 1, let second = Int(parts[1]) else { return false }
            return (16...31).contains(second)
        }
        return false
    }

    /// 从可达线路中挑选一条：优先与当前网络匹配（局域网 / 公网）的线路，同组内保留当前线路以避免无意义切换。
    ///
    /// - Returns: 没有任何可达线路时返回 nil，调用方应保持原线路并提示失联，而不是随意切换。
    public static func pickPreferredLine(
        lines: [ServerLine],
        reachableIDs: Set<String>,
        access: NetworkAccess,
        currentID: String?
    ) -> ServerLine? {
        let reachable = lines.filter { reachableIDs.contains($0.id) }
        guard !reachable.isEmpty else { return nil }
        let preferLAN = access == .lanCapable
        let preferred = reachable.filter { $0.isLAN == preferLAN }
        let pool = preferred.isEmpty ? reachable : preferred
        return pool.first { $0.id == currentID } ?? pool.first
    }
}
