#if os(macOS)
import AppKit
import SwiftUI
import VelaPlayer

/// macOS 的「画中画」：把播放器窗口原地变成置顶、无标题栏、锁定宽高比的小窗，贴在屏幕角落。
///
/// 不用系统画中画：KSPlayer 与带字幕的系统内核只能用样本缓冲区内容源，其小窗在 macOS 27.2 上不随小窗缩放、
/// 只露出放大的一角；原生 `AVPlayerLayer` 画中画又不显示应用渲染的字幕（PLAN 第 13、14 轮）。
/// 原地改窗口而不是新建面板：画面视图（`AVPlayerLayer` / KSPlayer 显示图层）、字幕层和会话都不用迁移或重建，两个内核通用。
///
/// 限制：普通窗口不能浮在其他应用的全屏空间之上（那需要非激活面板）；小窗在所有普通桌面上置顶。
@MainActor
final class MiniPlayerWindow {
    /// 进入小窗前的窗口外观，退出时原样还原。
    private struct Saved {
        var frame: NSRect
        var level: NSWindow.Level
        var collectionBehavior: NSWindow.CollectionBehavior
        var styleMask: NSWindow.StyleMask
        var titleVisibility: NSWindow.TitleVisibility
        var titlebarAppearsTransparent: Bool
        var contentAspectRatio: NSSize
        var contentMinSize: NSSize
    }

    /// 小窗默认宽度（pt）；本次运行内记住用户调整后的大小与位置，下次进入沿用。
    private static let defaultWidth: CGFloat = 400
    /// 小窗允许的最小宽度（pt），与 `PlayerScreen` 小窗模式的最小尺寸一致。
    static let minimumWidth: CGFloat = 240
    /// 贴角时与屏幕可用区域边缘的间距（pt）。
    private static let margin: CGFloat = 16
    @MainActor private static var lastMiniFrame: NSRect?

    private weak var window: NSWindow?
    private var saved: Saved?
    private var observers: [NSObjectProtocol] = []
    private var snapTask: Task<Void, Never>?

    var isActive: Bool { saved != nil }

    /// 进入小窗。窗口在全屏中时先退出全屏，等系统动画结束再缩小（全屏动画期间改尺寸会被系统覆盖）。
    func enter(_ window: NSWindow, videoSize: CGSize) {
        guard saved == nil else { return }
        if window.styleMask.contains(.fullScreen) {
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.didExitFullScreenNotification, object: window) { break }
                self?.enter(window, videoSize: videoSize)
            }
            window.toggleFullScreen(nil)
            return
        }
        self.window = window
        saved = Saved(
            frame: window.frame,
            level: window.level,
            collectionBehavior: window.collectionBehavior,
            styleMask: window.styleMask,
            titleVisibility: window.titleVisibility,
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            contentAspectRatio: window.contentAspectRatio,
            contentMinSize: window.contentMinSize
        )
        let aspect = videoSize.width > 0 && videoSize.height > 0 ? videoSize : CGSize(width: 16, height: 9)
        window.level = .floating
        // 不允许小窗本身再进入全屏；跟随用户切换桌面。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        setTrafficLightsHidden(true, in: window)
        window.contentMinSize = NSSize(width: Self.minimumWidth, height: Self.minimumWidth * aspect.height / aspect.width)
        window.contentAspectRatio = aspect
        window.setFrame(miniFrame(for: window, aspect: aspect), display: true, animate: true)
        observe(window)
    }

    /// 退出小窗，还原窗口原来的位置、尺寸与外观。
    func exit() {
        guard let saved, let window else {
            teardown()
            return
        }
        Self.lastMiniFrame = window.frame
        teardown()
        window.level = saved.level
        window.collectionBehavior = saved.collectionBehavior
        window.titleVisibility = saved.titleVisibility
        window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
        window.styleMask = saved.styleMask
        setTrafficLightsHidden(false, in: window)
        window.contentAspectRatio = saved.contentAspectRatio
        window.contentMinSize = saved.contentMinSize
        window.setFrame(saved.frame, display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 窗口关闭或会话结束时清理观察者（不还原外观）。
    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        snapTask?.cancel()
        snapTask = nil
        saved = nil
    }

    private func setTrafficLightsHidden(_ hidden: Bool, in window: NSWindow) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }

    /// 本次运行内上一次的小窗位置（宽高比按当前片源修正），没有时放在当前屏幕右下角。
    private func miniFrame(for window: NSWindow, aspect: CGSize) -> NSRect {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return window.frame }
        let width = Self.lastMiniFrame?.width ?? Self.defaultWidth
        let size = NSSize(width: width, height: (width * aspect.height / aspect.width).rounded())
        if let last = Self.lastMiniFrame, visible.contains(NSPoint(x: last.midX, y: last.midY)) {
            return snapped(NSRect(origin: last.origin, size: size), in: visible)
        }
        return NSRect(
            x: visible.maxX - size.width - Self.margin,
            y: visible.minY + Self.margin,
            width: size.width,
            height: size.height
        )
    }

    /// 与系统画中画一致：拖动结束后吸附到最近的屏幕角落。
    private func snapped(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var result = frame
        result.origin.x = frame.midX < visible.midX ? visible.minX + Self.margin : visible.maxX - frame.width - Self.margin
        result.origin.y = frame.midY < visible.midY ? visible.minY + Self.margin : visible.maxY - frame.height - Self.margin
        return result
    }

    /// 拖动过程中 `didMove` 连续触发：停止移动 0.25 秒且鼠标已松开时才吸附，避免拖动途中被拉走。
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSnap() }
        })
    }

    private func scheduleSnap() {
        snapTask?.cancel()
        snapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let window = self.window, self.isActive else { return }
            guard NSEvent.pressedMouseButtons == 0 else {
                self.scheduleSnap()
                return
            }
            guard let visible = window.screen?.visibleFrame else { return }
            let target = self.snapped(window.frame, in: visible)
            guard target.origin != window.frame.origin else { return }
            window.setFrame(target, display: true, animate: true)
        }
    }
}

/// 小窗上的控制层：悬停时压暗并显示关闭、回到窗口、快退 / 播放暂停 / 快进与细进度条；双击回到窗口；拖动画面移动小窗。
/// 图标直接画在约 35% 的压暗层上，不加玻璃（与系统画中画一致，HIG 对视频上方控件的建议）。
struct MiniPlayerOverlay: View {
    let controller: PlayerController
    let onRestore: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black.opacity(hovering ? 0.35 : 0)
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded(onRestore))
            if hovering {
                controls
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                iconButton("xmark", label: "关闭播放器", size: 14, action: onClose)
                Spacer()
                iconButton("pip.exit", label: "回到播放器窗口", size: 14, action: onRestore)
            }
            .padding(10)
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                iconButton("gobackward", label: "快退", size: 18, action: controller.skipBackward)
                iconButton(controller.isPlaying ? "pause.fill" : "play.fill", label: controller.isPlaying ? "暂停" : "播放", size: 26, action: controller.togglePlayPause)
                iconButton("goforward", label: "快进", size: 18, action: controller.skipForward)
            }
            Spacer(minLength: 0)
            MiniProgressBar(controller: controller)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    private func iconButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 16, height: size + 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 只读的细进度条：与系统画中画一致，小窗里不提供拖动定位（窗口太小，拖动会与移动小窗冲突）。
private struct MiniProgressBar: View {
    let controller: PlayerController

    var body: some View {
        let duration = controller.engine.duration
        let progress = duration > 0 ? min(max(controller.engine.currentTime / duration, 0), 1) : 0
        GeometryReader { proxy in
            Capsule().fill(.white.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: proxy.size.width * progress)
                }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
#endif
