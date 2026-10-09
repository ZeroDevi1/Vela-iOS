#if os(macOS)
import AppKit
import SwiftUI
import VelaPlayer

extension FocusedValues {
    /// 当前活动的播放器窗口的会话（`PlayerScreen` 以 `focusedSceneValue` 提供）；浏览窗口在前时为 nil。
    @Entry var playerSession: PlayerSession?
}

/// macOS 菜单栏「播放」：播放器的键盘操作。
///
/// 放在菜单栏而不是播放器视图的 `onKeyPress`：后者依赖视图持有键盘焦点，点按控制层按钮后焦点转移，快捷键就会失效；
/// 菜单项只要播放器窗口在前就能触发，也让用户能在菜单里查到快捷键。
/// 空格与方向键不带修饰键：播放器窗口内没有文本输入框，不会吞掉输入；没有播放器窗口在前时整组菜单项不出现，
/// 避免停用的菜单项拦截浏览窗口里（如搜索框）的按键。
public struct PlayerCommands: Commands {
    @FocusedValue(\.playerSession) private var session

    public init() {}

    public var body: some Commands {
        CommandMenu("播放") {
            if let session {
                content(session)
            } else {
                Button("没有正在播放的内容") {}.disabled(true)
            }
        }
    }

    @ViewBuilder
    private func content(_ session: PlayerSession) -> some View {
        let controller = session.controller
        Button(controller.isPlaying ? "暂停" : "播放") { controller.togglePlayPause() }
            .keyboardShortcut(.space, modifiers: [])
        Button("快退 \(controller.preferences.seekBackwardSeconds) 秒") { controller.skipBackward() }
            .keyboardShortcut(.leftArrow, modifiers: [])
        Button("快进 \(controller.preferences.seekForwardSeconds) 秒") { controller.skipForward() }
            .keyboardShortcut(.rightArrow, modifiers: [])
        Divider()
        Button("上一集") { session.playPreviousEpisode() }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(session.previousEpisode == nil)
        Button("下一集") { controller.playNextNow() }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(session.nextEpisode == nil)
        Divider()
        Button("加快播放") { step(controller, by: 0.25) }
            .keyboardShortcut("]", modifiers: [])
        Button("减慢播放") { step(controller, by: -0.25) }
            .keyboardShortcut("[", modifiers: [])
        Button("正常速度") { controller.engine.setRate(1) }
            .keyboardShortcut("\\", modifiers: [])
            .disabled(controller.engine.rate == 1)
        Divider()
        Button(controller.engine.isMuted ? "取消静音" : "静音") { controller.engine.setMuted(!controller.engine.isMuted) }
            .keyboardShortcut("m", modifiers: [])
        // Mac 的画中画是置顶小窗（`MiniPlayerWindow`）。
        Button(controller.isMiniWindow ? "退出画中画" : "画中画") { controller.requestPictureInPictureToggle() }
            .keyboardShortcut("p", modifiers: [.command, .option])
        // 系统画中画：可浮在其他应用的全屏空间之上（置顶小窗做不到），只支持系统内核，字幕靠码流字幕轨。
        Button(controller.isPictureInPictureActive ? "退出系统画中画" : "系统画中画") { controller.requestSystemPictureInPicture() }
            .keyboardShortcut("p", modifiers: [.command, .option, .shift])
        Button("截图") { session.captureScreenshot() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        Divider()
        Button("切换全屏") { NSApp.keyWindow?.toggleFullScreen(nil) }
            .keyboardShortcut("f", modifiers: [])
            .disabled(controller.isMiniWindow)
        // 按键实际由 `PlayerScreen` 的本地监听处理（窗口模式下 Esc 到不了菜单），这里的快捷键用于在菜单中展示。
        Button("退出全屏或关闭播放器") { Self.exitFullScreenOrClose(NSApp.keyWindow) }
            .keyboardShortcut(.escape, modifiers: [])
    }

    /// Esc：全屏时先退出全屏（macOS 习惯），窗口模式下关闭播放器（与左上角的关闭按钮一致）。
    /// 关闭窗口会经 `onDisappear` 结束会话。
    static func exitFullScreenOrClose(_ window: NSWindow?) {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.close()
        }
    }

    /// 与控制层倍速按钮相同：步长 0.25×，范围 0.25–4×，对齐到 0.05× 消除浮点误差。
    private func step(_ controller: PlayerController, by delta: Float) {
        let stepped = ((controller.engine.rate + delta) * 20).rounded() / 20
        controller.engine.setRate(min(max(stepped, 0.25), 4))
        controller.flash("\(controller.engine.rate.formatted())×", symbol: "speedometer")
    }

}
#endif
