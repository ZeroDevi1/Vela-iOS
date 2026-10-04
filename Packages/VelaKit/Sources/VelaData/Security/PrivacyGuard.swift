import Foundation
import LocalAuthentication
import Observation

/// 私密服务器的解锁状态。
///
/// 约束（与 Android 版一致）：解锁记录只放进程内存，不落盘；应用被系统回收或用户退出后需要重新验证。
/// 验证使用设备所有者认证（Face ID / Touch ID / 密码），取消或设备未设置密码时保持锁定。
@MainActor
@Observable
public final class PrivacyGuard {
    public private(set) var unlockedServerIDs: Set<String> = []
    public private(set) var lastError: String?

    public init() {}

    public func isUnlocked(_ serverID: String) -> Bool {
        unlockedServerIDs.contains(serverID)
    }

    /// - Returns: 认证成功返回 true；用户取消、无可用认证方式时返回 false 并写入 `lastError`（取消不记错误）。
    @discardableResult
    public func unlock(_ serverID: String, reason: String = "验证身份以访问私密服务器") async -> Bool {
        if isUnlocked(serverID) { return true }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            lastError = policyError?.localizedDescription ?? "设备未设置密码，无法使用私密服务器"
            return false
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            unlockedServerIDs.insert(serverID)
            lastError = nil
            return true
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 手动锁定（例如用户在设置中点「立即锁定」）。
    public func lockAll() {
        unlockedServerIDs.removeAll()
    }
}
