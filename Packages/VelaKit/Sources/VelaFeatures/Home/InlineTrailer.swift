import AVFoundation
import SwiftUI
import VelaCore
import VelaNetwork

/// 首页轮播居中卡片上的静音预告片（与 Android 版 `InlineTrailerPlayer` 对应）。
///
/// 只播放服务器上的本地预告片（`LocalTrailers`）：远程预告片多为 YouTube 页面地址，iOS 上不能直接取流。
/// 默认关闭（「媒体库配置 → 轮播自动播放预告片」），只在联网且非蜂窝 / 非低数据模式时播放；
/// 其他应用正在播放音频、或本应用自己的播放器（全屏 / 画中画）正在播放时都不播放：预告片只作为轮播的动态预览，
/// 不能打断或抢占正在进行的播放。视图离开屏幕、或开始正式播放时停止。
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
        // 全屏播放器盖在首页之上时首页不一定收到 onDisappear，正式播放开始就停掉预览。
        .onChange(of: app.presentedPlayback != nil) { _, presenting in
            if presenting { stop() }
        }
    }

    private var isAllowed: Bool {
        guard app.libraryPreferences.autoplayTrailers, app.network.isOnline, !app.network.isMetered else { return false }
        guard app.presentedPlayback == nil, app.pictureInPictureSession == nil else { return false }
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
        // 预览不进入后台播放、不投屏，避免被系统当作正式播放（锁屏 / 控制中心、画中画路由）。
        player.audiovisualBackgroundPlaybackPolicy = .pauses
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
        guard let ready = player.currentItem, ready.status == .readyToPlay, !Task.isCancelled, isAllowed else { return }
        // 只播画面：禁用音轨后不输出音频，不会和正式播放或其他应用争用音频会话（静音只是音量为 0，仍会参与音频会话）。
        for track in ready.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = false
        }
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
