import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaPlayer

/// 字幕层。播放中用 `TimelineView` 按 20 Hz 直接读取内核时间，避免依赖 0.25 秒的进度刷新导致字幕迟滞，
/// 也不会让整个播放界面随之重绘；非播放状态停止定时刷新，改按进度（含拖动后的 seek）更新。
///
/// 位置：竖屏且画面按比例适应时，字幕紧贴在画面下边缘之下（黑边内），观感接近横屏；
/// 其余情况（横屏、填充 / 拉伸、旋转、画面尺寸未知、下方黑边不够）贴近屏幕底部，控制层出现时上移让出进度条。
struct SubtitleOverlay: View {
    let controller: PlayerController
    let preferences: PlayerPreferences
    /// macOS 小窗：字号按窗口宽度缩小（以 720pt 宽为原始字号，最小 0.55 倍），贴底且不为控制层让位。
    var fitsSmallWindow = false

    /// 小窗字号缩放的基准宽度（pt）与下限。
    private static let smallWindowReferenceWidth: CGFloat = 720
    private static let smallWindowMinimumScale: CGFloat = 0.55

    /// 字幕顶部与画面下边缘的间距（pt）。
    private static let gapBelowVideo: CGFloat = 12
    /// 画面下方黑边至少要容纳约两行字幕，否则改为贴底。
    private static let minimumSpaceBelowVideo: CGFloat = 72

    /// KSPlayer 从视频流读取的内嵌字幕；与 WebVTT 字幕互斥。
    private var embeddedEngine: (any EmbeddedSubtitleProviding)? {
        (controller.engine as? any EmbeddedSubtitleProviding).flatMap { $0.hasEmbeddedSubtitle ? $0 : nil }
    }

    var body: some View {
        let track = controller.subtitleTrack
        let embedded = embeddedEngine
        if track != nil || embedded != nil {
            GeometryReader { proxy in
                let anchor = fitsSmallWindow ? nil : belowVideoAnchor(in: proxy)
                let scale = fitsSmallWindow
                    ? min(1, max(Self.smallWindowMinimumScale, proxy.size.width / Self.smallWindowReferenceWidth))
                    : 1
                let isPlaying = controller.engine.status == .playing
                // 只在暂停时订阅进度，播放中由时间线驱动，避免两路同时刷新。
                let pausedTime = isPlaying ? nil : controller.engine.currentTime
                TimelineView(.animation(minimumInterval: 0.05, paused: !isPlaying)) { _ in
                    let time = pausedTime ?? controller.engine.preciseCurrentTime
                    let images = track == nil ? embedded?.embeddedSubtitleImages(at: time) ?? [] : []
                    if !images.isEmpty {
                        pictureSubtitles(images, in: proxy.size)
                    } else {
                        if let text = track?.text(at: time) ?? embedded?.embeddedSubtitleText(at: time) {
                            subtitleText(text, scale: scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor == nil ? .bottom : .top)
                                .padding(.top, anchor ?? 0)
                                .padding(.bottom, anchor == nil ? bottomPadding(in: proxy, scale: scale) : 0)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: controller.controlsVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func subtitleText(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 20 * preferences.subtitleScale * scale, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.6), radius: 6)
            .padding(.horizontal, 32 * scale)
    }

    /// PGS 保留排版及特效位置，使用字幕画布映射到视频显示矩形，不按文本字号缩放或抬高。
    private func pictureSubtitles(_ images: [EmbeddedSubtitleImage], in size: CGSize) -> some View {
        let rotated = controller.quarterTurns % 2 != 0
        let bounds = rotated ? CGSize(width: size.height, height: size.width) : size
        let video = controller.engine.videoSize
        let factor = video.width > 0 && video.height > 0
            ? (controller.videoGravity == .fill ? max(bounds.width / video.width, bounds.height / video.height)
               : min(bounds.width / video.width, bounds.height / video.height)) : 1
        let display = controller.videoGravity == .stretch ? bounds : CGSize(width: video.width * factor, height: video.height * factor)
        return ZStack(alignment: .topLeading) {
            ForEach(images.indices, id: \.self) { index in
                let part = images[index]
                let sx = display.width / part.canvasSize.width
                let sy = display.height / part.canvasSize.height
                Image(decorative: part.image, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(part.image.width) * sx, height: CGFloat(part.image.height) * sy)
                    .offset(x: (bounds.width - display.width) / 2 + part.origin.x * sx,
                            y: (bounds.height - display.height) / 2 + part.origin.y * sy)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .rotationEffect(.degrees(Double(controller.quarterTurns) * 90))
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func bottomPadding(in proxy: GeometryProxy, scale: CGFloat) -> CGFloat {
        if fitsSmallWindow { return 12 + preferences.subtitleBottomOffset * scale }
        let controls = controller.controlsVisible ? PlayerLayout.controlsBottomInset(landscape: proxy.size.width > proxy.size.height) : 28
        return controls + preferences.subtitleBottomOffset
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
            .modifier(ControlsAwareBottomPadding(controlsVisible: controller.controlsVisible, hidden: 40))
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
                        .buttonStyle(.borderedProminent)
                        Button("取消") { controller.dismissUpNext() }
                            .buttonStyle(.bordered)
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
            .modifier(ControlsAwareBottomPadding(controlsVisible: controller.controlsVisible, hidden: 32))
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.snappy, value: upNext.countdown)
        }
    }
}

/// 播放器浮层的共享尺寸。
enum PlayerLayout {
    /// 控制层显示时，底部浮层（字幕、跳过片头、下一集）需要让出的高度。
    /// 竖屏：标题行 + 进度行 + 下方按钮行；横屏按钮并入进度行，只有标题行 + 进度行，
    /// 若沿用竖屏的高度，横屏字幕会被抬到画面约 1/4 处。
    static func controlsBottomInset(landscape: Bool) -> CGFloat {
        landscape ? 112 : 180
    }
}

/// 底部浮层的下边距：控制层显示时按横竖屏让出控件高度，隐藏时用 `hidden`。
/// 浮层视图铺满播放器，按自身尺寸判断横竖屏。
struct ControlsAwareBottomPadding: ViewModifier {
    let controlsVisible: Bool
    let hidden: CGFloat
    @State private var isLandscape = false

    func body(content: Content) -> some View {
        content
            .padding(.bottom, controlsVisible ? PlayerLayout.controlsBottomInset(landscape: isLandscape) : hidden)
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
    }
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
                        .buttonStyle(.borderedProminent)
                        Button("关闭") { session.screenshot = nil }
                            .buttonStyle(.bordered)
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
