import Foundation
import MediaPlayer
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 锁屏 / 控制中心 / 灵动岛 / macOS 菜单栏「正在播放」信息与远程控制。
///
/// 使用自定义 `AVPlayerLayer` 时系统不会自动接管，需要手动维护。同一时间只应有一个活跃实例。
@MainActor
public final class NowPlayingCenter {
    private weak var controller: PlayerController?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?

    public init() {}

    public func activate(controller: PlayerController) {
        deactivate()
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()

        register(center.playCommand) { $0.engine.play() }
        register(center.pauseCommand) { $0.engine.pause() }
        register(center.togglePlayPauseCommand) { $0.togglePlayPause() }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: controller.gestureSettings.seekBackwardSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: controller.gestureSettings.seekForwardSeconds)]
        register(center.skipBackwardCommand) { $0.skipBackward() }
        register(center.skipForwardCommand) { $0.skipForward() }

        let seek = center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                guard let controller = self?.controller else { return }
                await controller.engine.seek(to: position)
            }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, seek))
    }

    public func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        artworkTask?.cancel()
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    /// 播放状态变化（起播、暂停、拖动、倍速）时调用。系统根据 elapsed + rate 自行推算进度，无需每秒更新。
    public func update(title: String, subtitle: String?, duration: TimeInterval, position: TimeInterval, rate: Float) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
        #endif
    }

    /// 异步加载封面；失败时保持无封面，不影响其余信息。
    public func loadArtwork(from url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            guard let artwork = Self.makeArtwork(data) else { return }
            self?.artwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// 封面回调由 MediaPlayer 在后台队列调用，必须与主 actor 无关；
    /// 若在 `@MainActor` 上下文中直接写闭包，会被推断为主线程隔离并在运行时触发隔离断言崩溃。
    private nonisolated static func makeArtwork(_ data: Data) -> MPMediaItemArtwork? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        #else
        guard let image = NSImage(data: data) else { return nil }
        nonisolated(unsafe) let unsafeImage = image
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in unsafeImage }
        #endif
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor @Sendable (PlayerController) -> Void) {
        let target = command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let controller = self?.controller else { return }
                action(controller)
            }
            return .success
        }
        targets.append((command, target))
    }
}
