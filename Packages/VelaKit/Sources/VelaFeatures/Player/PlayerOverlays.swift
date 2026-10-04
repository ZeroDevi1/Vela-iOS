import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaPlayer

/// 字幕层。用 `TimelineView` 按 20 Hz 直接读取内核时间，避免依赖 0.25 秒的进度刷新导致字幕迟滞，
/// 也不会让整个播放界面随之重绘。
struct SubtitleOverlay: View {
    let controller: PlayerController
    let preferences: PlayerPreferences

    var body: some View {
        if let track = controller.subtitleTrack {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // 控制层出现时上移，避免与进度条重叠。
            .padding(.bottom, (controller.controlsVisible ? 110 : 28) + preferences.subtitleBottomOffset)
            .animation(.easeInOut(duration: 0.25), value: controller.controlsVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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
            .padding(.bottom, controller.controlsVisible ? 110 : 40)
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
                    Text("下一集").font(.caption).foregroundStyle(.white.opacity(0.7))
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
            .padding(.bottom, controller.controlsVisible ? 110 : 32)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.snappy, value: upNext.countdown)
        }
    }
}

/// 音轨 / 字幕 / 字幕延迟菜单。
struct TrackMenu: View {
    let session: PlayerSession

    var body: some View {
        Menu {
            if session.audioOptions.count > 1 {
                Picker("音轨", selection: Binding(
                    get: { session.selectedAudioIndex },
                    set: { if let index = $0 { session.selectAudio(index) } }
                )) {
                    ForEach(session.audioOptions) { option in
                        Text(option.title).tag(Optional(option.index))
                    }
                }
                .pickerStyle(.menu)
            }

            Picker("字幕", selection: Binding(
                get: { session.selectedSubtitleIndex },
                set: { session.selectSubtitle($0) }
            )) {
                Text("关闭").tag(Int?.none)
                ForEach(session.subtitleOptions) { option in
                    Text(option.requiresBurnIn ? "\(option.title)（需转码）" : option.title)
                        .tag(Optional(option.index))
                }
            }
            .pickerStyle(.menu)

            if session.controller.subtitleTrack != nil {
                Section("字幕延迟：\(delayText)") {
                    Button("提前 0.5 秒", systemImage: "minus") { session.adjustSubtitleDelay(by: -0.5) }
                    Button("延后 0.5 秒", systemImage: "plus") { session.adjustSubtitleDelay(by: 0.5) }
                }
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear { session.controller.pinControls(true) }
                .onDisappear { session.controller.pinControls(false) }
        } label: {
            Image(systemName: "captions.bubble").frame(width: 24, height: 24)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(session.isSwitchingStream || (session.audioOptions.count <= 1 && session.subtitleOptions.isEmpty))
        .accessibilityLabel("音轨与字幕")
    }

    private var delayText: String {
        let delay = session.controller.subtitleTrack?.delay ?? 0
        return delay == 0 ? "0" : String(format: "%+.1f 秒", delay)
    }
}
