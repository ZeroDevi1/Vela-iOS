import Foundation
import Network
import Observation
import VelaCore
import VelaNetwork

/// 多线路自动路由：监听网络变化、并发探测各线路、按局域网 / 公网偏好切换，失败线路冷却后再参与选择。
///
/// 触发时机：
/// - 网络类型变化（Wi-Fi ↔ 蜂窝、断网恢复），去抖 1.5 秒；
/// - 应用回到前台（30 秒内不重复）；
/// - 请求遇到连接层失败（同一服务器 10 秒内只处理一次），失败线路进入冷却；
/// - 用户在线路管理中手动「检测」。
///
/// 只处理开启了自动切换且有多条线路的服务器；手动检测只更新状态，不受自动切换开关影响也不会切换。
@MainActor
@Observable
public final class LineRouter {
    /// 切换提示，界面显示后调用 `dismissNotice()`。
    public struct Notice: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public var serverName: String
        public var lineName: String
        public var reason: Reason
        /// true 表示所有线路都不可达，没有切换。
        public var isFailure: Bool
    }

    public enum Reason: Sendable {
        case networkChanged, foreground, lineFailed, manual

        public var text: String {
            switch self {
            case .networkChanged: "网络变化"
            case .foreground: "回到前台"
            case .lineFailed: "当前线路连接失败"
            case .manual: "手动检测"
            }
        }
    }

    public private(set) var access: NetworkAccess = .lanCapable
    /// 线路 id → 最近一次探测结果。
    public private(set) var statuses: [String: MediaServerProbe.LineProbeResult] = [:]
    public private(set) var probingServerIDs: Set<String> = []
    public private(set) var notice: Notice?

    @ObservationIgnored private let store: ServerStore
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var cooldowns: [String: LineCooldown] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pathDebounce: Task<Void, Never>?
    @ObservationIgnored private var lastFailureHandled: [String: Date] = [:]
    @ObservationIgnored private var lastForegroundCheck: Date = .distantPast

    private static let pathDebounce: Duration = .milliseconds(1500)
    private static let failureThrottle: TimeInterval = 10
    private static let foregroundThrottle: TimeInterval = 30

    public init(store: ServerStore) {
        self.store = store
    }

    /// 开始监听网络。重复调用无效。首次回调会触发一次全量评估，用于启动时选择合适线路。
    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let access = Self.access(for: path)
            Task { @MainActor in self?.handlePathChange(access) }
        }
        monitor.start(queue: DispatchQueue(label: "app.vela.line-router"))
    }

    nonisolated private static func access(for path: NWPath) -> NetworkAccess {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { return .lanCapable }
        if path.usesInterfaceType(.cellular) { return .wan }
        // VPN / 其他接口：无法确定是否在局域网内，按可尝试局域网处理，探测结果会兜底。
        return .lanCapable
    }

    private func handlePathChange(_ newAccess: NetworkAccess) {
        let changed = newAccess != access
        access = newAccess
        guard newAccess != .offline else { return }
        // 首次回调（启动）也评估；之后只在类型变化时评估。
        guard changed || pathDebounce == nil else { return }
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.pathDebounce)
            guard !Task.isCancelled else { return }
            self?.evaluateAll(reason: .networkChanged)
        }
    }

    // MARK: - 触发入口

    public func evaluateAll(reason: Reason) {
        for server in store.servers where server.autoRouteEnabled && server.lines.count > 1 {
            evaluate(serverID: server.id, reason: reason)
        }
    }

    public func appDidBecomeActive() {
        guard Date.now.timeIntervalSince(lastForegroundCheck) > Self.foregroundThrottle else { return }
        lastForegroundCheck = .now
        evaluateAll(reason: .foreground)
    }

    /// 来自 client 的连接层失败。可在任意线程调用。
    nonisolated public func reportTransportFailure(serverID: String, baseURL: URL) {
        Task { @MainActor in self.handleTransportFailure(serverID: serverID, baseURL: baseURL) }
    }

    private func handleTransportFailure(serverID: String, baseURL: URL) {
        guard let server = store.servers.first(where: { $0.id == serverID }),
              server.activeLine.url == baseURL,
              server.autoRouteEnabled, server.lines.count > 1 else { return }
        if let last = lastFailureHandled[serverID], Date.now.timeIntervalSince(last) < Self.failureThrottle { return }
        lastFailureHandled[serverID] = .now
        cooldowns[serverID, default: LineCooldown()].markFailed(server.activeLineID)
        Log.network.info("线路连接失败，重新探测：\(server.displayName, privacy: .private)")
        evaluate(serverID: serverID, reason: .lineFailed)
    }

    /// 用户手动检测：探测所有线路并刷新状态，不切换。
    public func checkLines(serverID: String) {
        evaluate(serverID: serverID, reason: .manual, allowSwitch: false)
    }

    /// 用户手动选择线路：立即切换，并清除该线路的冷却。
    public func switchManually(serverID: String, lineID: String) {
        cooldowns[serverID]?.clear(lineID)
        store.setActiveLine(serverID: serverID, lineID: lineID)
    }

    public func dismissNotice() {
        notice = nil
    }

    /// 校验新线路地址：按添加服务器的规则补全协议与 `/emby`，返回第一个确认是同一台服务器的地址。
    public func resolveNewLine(input: String, for server: SavedServer) async throws -> URL {
        let candidates = ServerDiscovery.candidates(for: input)
        guard !candidates.isEmpty else { throw LineError.invalidAddress }
        var sawMismatch = false
        for url in candidates {
            switch await MediaServerProbe.probeLine(url, expectedServerID: server.serverInstanceID, timeout: 6) {
            case .reachable: return url
            case .mismatch: sawMismatch = true
            case .unreachable: continue
            }
        }
        throw sawMismatch ? LineError.differentServer : LineError.unreachable
    }

    public enum LineError: LocalizedError {
        case invalidAddress, unreachable, differentServer

        public var errorDescription: String? {
            switch self {
            case .invalidAddress: "地址无效"
            case .unreachable: "无法连接到该地址"
            case .differentServer: "该地址上是另一台服务器，不能作为此服务器的线路"
            }
        }
    }

    // MARK: - 探测与切换

    private func evaluate(serverID: String, reason: Reason, allowSwitch: Bool = true) {
        guard tasks[serverID] == nil,
              let server = store.servers.first(where: { $0.id == serverID }) else { return }
        probingServerIDs.insert(serverID)
        let lines = server.lines
        let expectedID = server.serverInstanceID
        tasks[serverID] = Task { [weak self] in
            let results = await withTaskGroup(of: (String, MediaServerProbe.LineProbeResult).self) { group in
                for line in lines {
                    group.addTask { (line.id, await MediaServerProbe.probeLine(line.url, expectedServerID: expectedID)) }
                }
                var collected: [String: MediaServerProbe.LineProbeResult] = [:]
                for await (id, result) in group { collected[id] = result }
                return collected
            }
            self?.apply(results, serverID: serverID, reason: reason, allowSwitch: allowSwitch)
        }
    }

    private func apply(
        _ results: [String: MediaServerProbe.LineProbeResult],
        serverID: String,
        reason: Reason,
        allowSwitch: Bool
    ) {
        tasks[serverID] = nil
        probingServerIDs.remove(serverID)
        statuses.merge(results) { _, new in new }
        // 用户可能在探测期间删除了服务器或关闭了自动切换。
        guard let server = store.servers.first(where: { $0.id == serverID }) else { return }

        var cooldown = cooldowns[serverID, default: LineCooldown()]
        var reachable: Set<String> = []
        for (lineID, result) in results {
            if case .reachable = result {
                reachable.insert(lineID)
            } else {
                cooldown.markFailed(lineID)
            }
        }
        cooldowns[serverID] = cooldown

        guard allowSwitch, server.autoRouteEnabled else { return }
        switch LineRouting.decide(lines: server.lines, reachableIDs: reachable, access: access, currentID: server.activeLineID, cooldown: cooldown) {
        case .keep:
            break
        case .switchTo(let line):
            store.setActiveLine(serverID: serverID, lineID: line.id)
            Log.network.info("线路已切换（\(reason.text, privacy: .public)）")
            notice = Notice(serverName: server.displayName, lineName: LineRouting.displayName(of: line), reason: reason, isFailure: false)
        case .unreachable:
            // 只在当前线路确实失败时提示，避免网络切换瞬间的误报。
            if reason == .lineFailed {
                notice = Notice(serverName: server.displayName, lineName: LineRouting.displayName(of: server.activeLine), reason: reason, isFailure: true)
            }
        }
    }
}
