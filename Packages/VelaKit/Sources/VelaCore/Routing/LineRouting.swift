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

/// 线路失败冷却：失败过的线路在冷却期内不作为切换目标，避免网络抖动时在两条线路间来回切换。
///
/// 只记录时间戳，不持久化：重启应用后所有线路重新参与选择。
public struct LineCooldown: Sendable {
    /// 冷却时长（秒）。
    public var duration: TimeInterval
    private var failedAt: [String: Date] = [:]

    public init(duration: TimeInterval = 60) {
        self.duration = duration
    }

    public mutating func markFailed(_ lineID: String, at date: Date = .now) {
        failedAt[lineID] = date
    }

    /// 线路恢复可达（探测成功）时清除冷却。
    public mutating func clear(_ lineID: String) {
        failedAt[lineID] = nil
    }

    public func isCoolingDown(_ lineID: String, now: Date = .now) -> Bool {
        guard let date = failedAt[lineID] else { return false }
        return now.timeIntervalSince(date) < duration
    }
}

extension LineRouting {
    /// 一次探测后的切换决策。
    public enum Decision: Equatable, Sendable {
        /// 当前线路就是最佳选择（或无需切换）。
        case keep
        /// 切换到指定线路。
        case switchTo(ServerLine)
        /// 所有线路都不可达：保持原线路，界面提示失联。
        case unreachable
    }

    /// 根据探测结果决定是否切换。冷却中的线路即使探测成功也只在没有其他可达线路时才会被选中。
    public static func decide(
        lines: [ServerLine],
        reachableIDs: Set<String>,
        access: NetworkAccess,
        currentID: String,
        cooldown: LineCooldown,
        now: Date = .now
    ) -> Decision {
        guard access != .offline else { return .keep }
        let warm = reachableIDs.filter { !cooldown.isCoolingDown($0, now: now) }
        let candidates = warm.isEmpty ? reachableIDs : warm
        guard let picked = pickPreferredLine(lines: lines, reachableIDs: candidates, access: access, currentID: currentID) else {
            return .unreachable
        }
        return picked.id == currentID ? .keep : .switchTo(picked)
    }

    /// 自动生成的线路名：用户未命名时按局域网 / 公网区分。
    public static func displayName(of line: ServerLine) -> String {
        let name = line.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        return line.isLAN ? "局域网" : "公网"
    }
}
