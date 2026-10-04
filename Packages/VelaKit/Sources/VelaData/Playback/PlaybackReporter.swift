import Foundation
import VelaCore
import VelaNetwork

/// 播放状态上报的节流与生命周期管理。
///
/// 规则：
/// - 起播发送 Start；之后每 `progressInterval` 秒发送 `timeupdate`，暂停 / 继续 / 拖动后立即发送。
/// - 停止时发送 Stopped，转码时再结束服务器端转码进程。
/// - 上报失败只记日志，不影响播放；服务器暂时不可达时下次心跳会带上最新位置。
@MainActor
public final class PlaybackReporter {
    /// 进度心跳间隔（秒）。与官方客户端一致，过于频繁会加重服务器数据库写入。
    public static let progressInterval: TimeInterval = 10

    private let client: MediaServerClient
    private var state: PlaybackReportState
    private let isTranscoding: Bool
    private var lastProgressAt: Date = .distantPast
    private var started = false
    private var stopped = false
    /// 串行发送链：保证 Start → Progress → Stopped 按顺序到达服务器。
    private var chain: Task<Void, Never>?

    public init(client: MediaServerClient, state: PlaybackReportState, isTranscoding: Bool) {
        self.client = client
        self.state = state
        self.isTranscoding = isTranscoding
    }

    public func start() {
        guard !started else { return }
        started = true
        lastProgressAt = .now
        send(.start, state)
    }

    /// 由播放循环约每秒调用一次；内部判断是否需要发送。
    public func tick(position: TimeInterval, isPaused: Bool) {
        guard started, !stopped else { return }
        let pauseChanged = isPaused != state.isPaused
        state.position = position
        state.isPaused = isPaused
        if pauseChanged {
            lastProgressAt = .now
            send(.progress(eventName: isPaused ? "pause" : "unpause"), state)
        } else if !isPaused, Date.now.timeIntervalSince(lastProgressAt) >= Self.progressInterval {
            lastProgressAt = .now
            send(.progress(eventName: "timeupdate"), state)
        }
    }

    /// 拖动或切换轨道后立即同步位置。
    public func flush(position: TimeInterval, audioStreamIndex: Int?, subtitleStreamIndex: Int?) {
        guard started, !stopped else { return }
        state.position = position
        state.audioStreamIndex = audioStreamIndex
        state.subtitleStreamIndex = subtitleStreamIndex
        lastProgressAt = .now
        send(.progress(eventName: "timeupdate"), state)
    }

    /// 结束上报。返回的 Task 可等待，但调用方关闭界面时通常不需要等待。
    @discardableResult
    public func stop(position: TimeInterval) -> Task<Void, Never> {
        guard started, !stopped else { return Task {} }
        stopped = true
        state.position = position
        let client = client
        let state = state
        let isTranscoding = isTranscoding
        let previous = chain
        let task = Task {
            await previous?.value
            do {
                try await client.reportPlayback(.stopped, state: state)
            } catch {
                Log.player.error("Stopped 上报失败：\(error.localizedDescription, privacy: .public)")
            }
            if isTranscoding, let session = state.playSessionID {
                try? await client.stopActiveEncodings(playSessionID: session)
            }
        }
        chain = task
        return task
    }

    private func send(_ event: MediaServerClient.ReportEvent, _ state: PlaybackReportState) {
        let client = client
        let previous = chain
        chain = Task {
            await previous?.value
            do {
                try await client.reportPlayback(event, state: state)
            } catch {
                Log.player.error("播放上报失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
