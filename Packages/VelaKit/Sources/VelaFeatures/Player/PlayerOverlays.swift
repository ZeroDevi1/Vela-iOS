import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaPlayer

/// 字幕层。用 `TimelineView` 按 20 Hz 直接读取内核时间，避免依赖 0.25 秒的进度刷新导致字幕迟滞，
/// 也不会让整个播放界面随之重绘。
///
/// 位置：竖屏且画面按比例适应时，字幕紧贴在画面下边缘之下（黑边内），观感接近横屏；
/// 其余情况（横屏、填充 / 拉伸、旋转、画面尺寸未知、下方黑边不够）贴近屏幕底部，控制层出现时上移让出进度条。
struct SubtitleOverlay: View {
    let controller: PlayerController
    let preferences: PlayerPreferences

    /// 字幕顶部与画面下边缘的间距（pt）。
    private static let gapBelowVideo: CGFloat = 12
    /// 画面下方黑边至少要容纳约两行字幕，否则改为贴底。
    private static let minimumSpaceBelowVideo: CGFloat = 72

    var body: some View {
        if let track = controller.subtitleTrack {
            GeometryReader { proxy in
                let anchor = belowVideoAnchor(in: proxy)
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    if let text = track.text(at: controller.engine.preciseCurrentTime) {
                        Text(text)
                            .font(.system(size: 20 * preferences.subtitleScale, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                            .padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor == nil ? .bottom : .top)
                .padding(.top, anchor ?? 0)
                // 控制层出现时上移，避免与进度条重叠。
                .padding(.bottom, anchor == nil ? (controller.controlsVisible ? PlayerLayout.controlsBottomInset : 28) + preferences.subtitleBottomOffset : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: controller.controlsVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 竖屏时字幕顶部在本视图坐标系中的 y；不适用时返回 nil。
    ///
    /// 画面表面忽略安全区铺满整个屏幕，而本视图位于安全区内，因此先换算到全屏坐标再减去顶部安全区。
    private func belowVideoAnchor(in proxy: GeometryProxy) -> CGFloat? {
        let video = controller.engine.videoSize
        guard controller.videoGravity == .fit, controller.quarterTurns % 2 == 0,
              video.width > 0, video.height > 0 else { return nil }
        let insets = proxy.safeAreaInsets
        let fullWidth = proxy.size.width + insets.leading + insets.trailing
        let fullHeight = proxy.size.height + insets.top + insets.bottom
        guard fullHeight > fullWidth else { return nil }
        let videoHeight = min(fullHeight, fullWidth * video.height / video.width)
        let videoBottom = (fullHeight + videoHeight) / 2
        let spaceBelow = fullHeight - insets.bottom - videoBottom
        guard spaceBelow >= Self.minimumSpaceBelowVideo else { return nil }
        // 「字幕位置」设置在竖屏下表示向上抬高，与横屏时距底部的含义一致。
        return max(0, videoBottom - insets.top + Self.gapBelowVideo - preferences.subtitleBottomOffset)
    }
}

/// 「跳过片头 / 回顾」按钮，处于对应区段时显示在右下角，不随控制层隐藏。
struct SkipSegmentButton: View {
    let controller: PlayerController

    var body: some View {
        if let segment = controller.activeSkippableSegment, segment.end != nil, controller.upNext == nil {
            Button {
                controller.skip(segment)
            } label: {
                Label(title(segment.kind), systemImage: "forward.end.fill")
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 24)
            .padding(.bottom, controller.controlsVisible ? PlayerLayout.controlsBottomInset : 40)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.snappy, value: controller.controlsVisible)
        }
    }

    private func title(_ kind: PlaybackSegment.Kind) -> String {
        switch kind {
        case .intro: "跳过片头"
        case .recap: "跳过回顾"
        case .preview: "跳过预告"
        case .outro: "跳过片尾"
        }
    }
}

/// 「下一集」卡片：缩略图 + 标题 + 倒计时进度。
struct UpNextCard: View {
    let controller: PlayerController

    var body: some View {
        if let upNext = controller.upNext {
            HStack(spacing: 12) {
                RemoteArtwork(url: upNext.imageURL, placeholderSymbol: "play.rectangle")
                    .frame(width: 120, height: 68)
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(upNext.heading).font(.caption).foregroundStyle(.white.opacity(0.7))
                    Text(upNext.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        Button {
                            controller.playNextNow()
                        } label: {
                            Label(upNext.countdown.map { "播放（\($0)）" } ?? "播放", systemImage: "play.fill")
                                .contentTransition(.numericText(countsDown: true))
                        }
                        .buttonStyle(.glassProminent)
                        Button("取消") { controller.dismissUpNext() }
                            .buttonStyle(.glass)
                    }
                    .font(.subheadline)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 20)
            .padding(.bottom, controller.controlsVisible ? PlayerLayout.controlsBottomInset : 32)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.snappy, value: upNext.countdown)
        }
    }
}

/// 播放器浮层的共享尺寸。
enum PlayerLayout {
    /// 控制层显示时，底部浮层（字幕、跳过片头、下一集）需要让出的高度：次级按钮行 + 进度行 + 传输行。
    static let controlsBottomInset: CGFloat = 180
}

/// 截图完成提示：缩略图 + 分享（可存入照片 / 文件）。不自动收起：分享面板打开期间移除视图会连带关闭面板。
struct ScreenshotToast: View {
    let session: PlayerSession

    var body: some View {
        if let cgImage = session.screenshot {
            let image = Image(decorative: cgImage, scale: 1)
            HStack(spacing: 12) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 72)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text("已截图").font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        ShareLink(item: image, preview: SharePreview(session.controller.source?.title ?? "截图", image: image)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glassProminent)
                        Button("关闭") { session.screenshot = nil }
                            .buttonStyle(.glass)
                    }
                    .font(.subheadline)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 64)
            .padding(.trailing, 20)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .onAppear { session.controller.pinControls(true) }
            .onDisappear { session.controller.pinControls(false) }
        }
    }
}
