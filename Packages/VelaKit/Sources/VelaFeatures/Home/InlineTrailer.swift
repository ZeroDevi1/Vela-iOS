import AVFoundation
import SwiftUI
import VelaCore
import VelaNetwork

/// 首页轮播居中卡片上的静音预告片（与 Android 版 `InlineTrailerPlayer` 对应）。
///
/// 只播放服务器上的本地预告片（`LocalTrailers`）：远程预告片多为 YouTube 页面地址，iOS 上不能直接取流。
/// 默认关闭（「媒体库配置 → 轮播自动播放预告片」），只在联网且非蜂窝 / 非低数据模式时播放；
/// 其他应用正在播放音频时也不播放（即使静音，开始播放也可能打断它们）。视图离开屏幕时停止。
struct InlineTrailerOverlay: View {
    let item: MediaItem
    /// 预告片开始播放 / 结束（或失败）时回调，轮播据此暂停与恢复自动翻页。
    let onStart: () -> Void
    let onFinish: () -> Void
    @Environment(AppModel.self) private var app
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            if let player {
                TrailerPlayerLayer(player: player)
                    .opacity(isPlaying ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: isPlaying)
            }
        }
        .allowsHitTesting(false)
        .task(id: item.id) {
            await run()
            stop()
        }
        .onDisappear { stop() }
    }

    private var isAllowed: Bool {
        guard app.libraryPreferences.autoplayTrailers, app.network.isOnline, !app.network.isMetered else { return false }
        #if os(iOS)
        if AVAudioSession.sharedInstance().isOtherAudioPlaying { return false }
        #endif
        return true
    }

    private func run() async {
        guard isAllowed, item.kind == .movie || item.kind == .series,
              let client = app.client(forServerID: item.serverID),
              let url = await TrailerLookup.shared.url(for: item, client: client), !Task.isCancelled else { return }
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        #if os(iOS)
        player.allowsExternalPlayback = false
        #endif
        self.player = player
        // 等待可播放（最多 10 秒），避免在加载过程中显示黑帧。
        for _ in 0..<50 {
            if player.currentItem?.status == .readyToPlay { break }
            if player.currentItem?.status == .failed || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard player.currentItem?.status == .readyToPlay, !Task.isCancelled else { return }
        player.play()
        isPlaying = true
        onStart()
        defer { onFinish() }
        guard let current = player.currentItem else { return }
        for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: current) {
            break
        }
    }

    private func stop() {
        player?.pause()
        player = nil
        isPlaying = false
    }
}

/// 条目的本地预告片地址，本次运行内缓存（轮播反复经过同一条目时不重复请求）；没有预告片记为 nil。
@MainActor
final class TrailerLookup {
    static let shared = TrailerLookup()
    private var cache: [String: URL?] = [:]

    func url(for item: MediaItem, client: MediaServerClient) async -> URL? {
        let key = "\(item.serverID)/\(item.id)"
        if let cached = cache[key] { return cached }
        let trailer = try? await client.localTrailers(itemID: item.id).first
        let url = trailer.flatMap { try? client.directStreamURL(itemID: $0.id, mediaSourceID: $0.id, playSessionID: nil, container: nil) }
        cache[key] = url
        return url
    }
}

#if os(iOS)
private struct TrailerPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#else
private struct TrailerPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
#endif
