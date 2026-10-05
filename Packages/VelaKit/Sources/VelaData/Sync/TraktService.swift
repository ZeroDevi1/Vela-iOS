import Foundation
import Observation
import VelaCore
import VelaNetwork

/// Trakt 同步：设备码授权、令牌刷新、播放 scrobble。
///
/// Client ID / Secret 与令牌都存 Keychain。scrobble 失败只记日志，不影响播放。
@MainActor
@Observable
public final class TraktService {
    /// 授权进行中：展示给用户的验证码与网址。
    public struct PendingAuthorization: Equatable, Sendable {
        public var userCode: String
        public var verificationURL: URL
    }

    public private(set) var clientID: String
    public private(set) var isConnected: Bool
    public private(set) var pending: PendingAuthorization?
    public private(set) var lastError: String?
    /// 是否在播放时 scrobble。
    public var scrobbleEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobbleEnabled, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var tokens: TraktClient.Tokens?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let clientIDAccount = "trakt.clientID"
    private static let clientSecretAccount = "trakt.clientSecret"
    private static let tokensAccount = "trakt.tokens"
    private static let enabledKey = "trakt.scrobbleEnabled"

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        clientID = (try? keychain.string(for: Self.clientIDAccount)) ?? ""
        let stored = ((try? keychain.string(for: Self.tokensAccount)) ?? nil).flatMap { Data($0.utf8) }
        tokens = stored.flatMap { try? JSONDecoder().decode(TraktClient.Tokens.self, from: $0) }
        isConnected = tokens != nil
        scrobbleEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var client: TraktClient? {
        guard let secret = try? keychain.string(for: Self.clientSecretAccount), !clientID.isEmpty, !secret.isEmpty else { return nil }
        return TraktClient(clientID: clientID, clientSecret: secret)
    }

    public var hasCredentials: Bool { client != nil }

    public func saveCredentials(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.set(id, for: Self.clientIDAccount)
        try keychain.set(secret, for: Self.clientSecretAccount)
        self.clientID = id
    }

    // MARK: - 授权

    /// 开始设备码授权：显示验证码，后台按服务端给的间隔轮询，用户在网页确认后保存令牌。
    public func beginAuthorization() async {
        guard let client else {
            lastError = "请先填写 Client ID 与 Client Secret"
            return
        }
        pollTask?.cancel()
        lastError = nil
        do {
            let code = try await client.requestDeviceCode()
            pending = PendingAuthorization(userCode: code.userCode, verificationURL: code.verificationURL)
            pollTask = Task { [weak self] in await self?.poll(client: client, code: code) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func cancelAuthorization() {
        pollTask?.cancel()
        pending = nil
    }

    private func poll(client: TraktClient, code: TraktClient.DeviceCode) async {
        var interval = code.interval
        let deadline = Date.now.addingTimeInterval(code.expiresIn)
        while !Task.isCancelled, Date.now < deadline {
            try? await Task.sleep(for: .seconds(interval))
            do {
                let tokens = try await client.pollToken(deviceCode: code.deviceCode)
                try store(tokens)
                pending = nil
                return
            } catch TraktClient.TraktError.pending {
                continue
            } catch TraktClient.TraktError.slowDown {
                interval += 1
            } catch {
                lastError = error.localizedDescription
                pending = nil
                return
            }
        }
        if !Task.isCancelled {
            lastError = TraktClient.TraktError.expired.localizedDescription
            pending = nil
        }
    }

    private func store(_ tokens: TraktClient.Tokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try keychain.set(String(decoding: data, as: UTF8.self), for: Self.tokensAccount)
        self.tokens = tokens
        isConnected = true
    }

    public func disconnect() {
        try? keychain.remove(Self.tokensAccount)
        tokens = nil
        isConnected = false
    }

    // MARK: - Scrobble

    /// 播放状态变化时调用；未连接、已关闭或条目没有 provider id 时直接返回。
    public func scrobble(_ action: TraktScrobble.Action, item: MediaItem, position: TimeInterval, duration: TimeInterval) {
        guard scrobbleEnabled, isConnected, let client, TraktScrobble.body(for: item) != nil else { return }
        let progress = TraktScrobble.progress(position: position, duration: duration)
        Task {
            do {
                let token = try await validAccessToken(client: client)
                try await client.scrobble(action, item: item, progress: progress, accessToken: token)
            } catch {
                Log.network.error("Trakt scrobble 失败：\(error.localizedDescription, privacy: .public)")
                if (error as? TraktClient.TraktError) == .unauthorized { disconnect() }
            }
        }
    }

    private func validAccessToken(client: TraktClient) async throws -> String {
        guard let tokens else { throw TraktClient.TraktError.unauthorized }
        guard tokens.isExpired else { return tokens.accessToken }
        let refreshed = try await client.refresh(tokens)
        try store(refreshed)
        return refreshed.accessToken
    }
}
