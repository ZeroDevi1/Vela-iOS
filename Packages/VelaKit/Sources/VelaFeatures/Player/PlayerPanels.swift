import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork
import VelaPlayer

/// 播放器面板（横屏贴右、iPhone 竖屏贴底）。打开时隐藏控制层，点击面板外关闭。
enum PlayerPanel: String, Identifiable {
    case info, audio, subtitle, episodes, chapters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "播放信息"
        case .audio: "音轨"
        case .subtitle: "字幕"
        case .episodes: "剧集"
        case .chapters: "章节"
        }
    }
}

struct PlayerPanelHost: View {
    let panel: PlayerPanel
    let session: PlayerSession
    let onClose: () -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// iPhone 竖屏时面板从底部弹出、占满宽度；其余情况（横屏、iPad、Mac）贴右侧。
    private var isBottomSheet: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && verticalSizeClass == .regular
        #else
        false
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: isBottomSheet ? .bottom : .topTrailing) {
                // 面板外区域：点击关闭，同时挡住下面的手势层。
                Color.black.opacity(0.25)
                    .contentShape(.rect)
                    .onTapGesture(perform: onClose)
                    .ignoresSafeArea()

                sized(card, in: proxy.size)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .padding(isBottomSheet ? .all : [.vertical, .trailing], 12)
            }
        }
        .foregroundStyle(.white)
        .transition(.move(edge: isBottomSheet ? .bottom : .trailing).combined(with: .opacity))
        .onAppear { session.controller.pinControls(true) }
        .onDisappear { session.controller.pinControls(false) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            HStack {
                Text(panel.title).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭面板")
            }
            content
        }
        .padding(VelaTheme.Spacing.l)
    }

    /// 音轨 / 字幕通常只有几行：高度随内容，超过上限再滚动；剧集 / 章节 / 播放信息是长列表，直接用上限高度。
    /// 竖屏底部面板上限为屏高 60%，侧边面板上限为整屏高度。
    @ViewBuilder
    private func sized(_ card: some View, in size: CGSize) -> some View {
        let width = isBottomSheet ? min(600, size.width - 24) : min(400, size.width - 24)
        let maxHeight = isBottomSheet ? size.height * 0.6 : size.height - 24
        switch panel {
        case .audio, .subtitle:
            // 先限制最大高度，再按理想高度（内容高度）收缩。
            card
                .frame(width: width)
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
        case .info, .episodes, .chapters:
            card
                .frame(width: width)
                .frame(maxHeight: maxHeight, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .info: PlaybackInfoPanel(session: session)
        case .audio: AudioPanel(session: session)
        case .subtitle: SubtitlePanel(session: session)
        case .episodes: EpisodesPanel(session: session, onPicked: onClose)
        case .chapters: ChaptersPanel(session: session, onPicked: onClose)
        }
    }
}

// MARK: - 轨道行

/// 两行轨道信息：服务器原始标题 + 中文语言名 / 参数 / 标记。
private struct TrackRow: View {
    let label: TrackLabel
    var note: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VelaTheme.Spacing.m) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.title).font(.body).lineLimit(2)
                    if let line = label.detailLine {
                        Text(line).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AudioPanel: View {
    let session: PlayerSession

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let isMuted = session.controller.engine.isMuted
                TrackRow(label: TrackLabel(title: "静音", details: [], flags: []), isSelected: isMuted) {
                    session.muteAudio()
                }
                ForEach(session.audioOptions) { option in
                    TrackRow(label: option.label, isSelected: !isMuted && option.index == session.selectedAudioIndex) {
                        session.selectAudio(option.index)
                    }
                    .disabled(session.isSwitchingStream)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct SubtitlePanel: View {
    let session: PlayerSession
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.playerPreferences
        ScrollView {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TrackRow(
                        label: TrackLabel(title: "关闭", details: [], flags: []),
                        isSelected: session.selectedSubtitleIndex == nil
                    ) { session.selectSubtitle(nil) }
                    ForEach(session.subtitleOptions) { option in
                        TrackRow(
                            label: option.label,
                            note: option.requiresBurnIn ? "图形字幕，需服务器转码烧录" : nil,
                            isSelected: option.index == session.selectedSubtitleIndex
                        ) { session.selectSubtitle(option.index) }
                        .disabled(session.isSwitchingStream)
                    }
                }

                if session.hasActiveSubtitle {
                    Divider().overlay(.white.opacity(0.3))
                    HStack {
                        Text("延迟")
                        Spacer()
                        Button("提前 0.5 秒", systemImage: "minus") { session.adjustSubtitleDelay(by: -0.5) }
                            .labelStyle(.iconOnly)
                        Text(delayText)
                            .monospacedDigit()
                            .frame(minWidth: 64)
                            .onTapGesture(count: 2) { session.adjustSubtitleDelay(by: -session.subtitleDelay) }
                            .accessibilityHint("轻点两下重置")
                        Button("延后 0.5 秒", systemImage: "plus") { session.adjustSubtitleDelay(by: 0.5) }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    HStack {
                        Text("字号")
                        Slider(value: $preferences.subtitleScale, in: 0.6...2.0, step: 0.1)
                        Text("\(Int(preferences.subtitleScale * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("位置")
                        Slider(value: $preferences.subtitleBottomOffset, in: 0...200, step: 4)
                        Text("+\(Int(preferences.subtitleBottomOffset))").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .tint(.white)
    }

    private var delayText: String {
        let delay = session.subtitleDelay
        return delay == 0 ? "0 秒" : String(format: "%+.1f 秒", delay)
    }
}

// MARK: - 剧集 / 章节

private struct EpisodesPanel: View {
    let session: PlayerSession
    let onPicked: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                    ForEach(session.seasonEpisodes) { episode in
                        let isCurrent = episode.id == session.item?.id
                        Button {
                            session.playEpisode(episode)
                            onPicked()
                        } label: {
                            HStack(spacing: VelaTheme.Spacing.m) {
                                RemoteArtwork(url: session.episodeImageURL(episode), placeholderSymbol: "play.rectangle")
                                    .frame(width: 128, height: 72)
                                    .overlay(alignment: .bottom) {
                                        if let fraction = episode.playedFraction, !isCurrent {
                                            ProgressView(value: fraction).tint(VelaTheme.accent).padding(4)
                                        }
                                    }
                                    .clipShape(.rect(cornerRadius: 10))
                                    .overlay {
                                        if isCurrent {
                                            RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2)
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)")
                                        .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        if isCurrent { Text("正在播放") }
                                        if let runtime = MediaFormat.runtime(episode.runTimeTicks) { Text(runtime) }
                                        if episode.isPlayed { Image(systemName: "checkmark.circle.fill") }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                        .id(episode.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let id = session.item?.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct ChaptersPanel: View {
    let session: PlayerSession
    let onPicked: () -> Void

    var body: some View {
        let chapters = session.chapters
        let now = session.controller.engine.currentTime
        let currentIndex = chapters.lastIndex { $0.chapter.start <= now + 0.5 }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                    ForEach(Array(chapters.enumerated()), id: \.element.index) { position, entry in
                        Button {
                            Task { await session.controller.engine.seek(to: entry.chapter.start) }
                            onPicked()
                        } label: {
                            HStack(spacing: VelaTheme.Spacing.m) {
                                RemoteArtwork(
                                    url: session.chapterImageURL(index: entry.index, chapter: entry.chapter),
                                    placeholderSymbol: "list.bullet.rectangle"
                                )
                                .frame(width: 128, height: 72)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay {
                                    if position == currentIndex {
                                        RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.chapter.name ?? "章节 \(position + 1)").font(.subheadline).lineLimit(2)
                                    Text(PlayerTime.format(entry.chapter.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(position)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let currentIndex { proxy.scrollTo(currentIndex, anchor: .center) }
            }
        }
    }
}

// MARK: - 播放信息

private struct PlaybackInfoPanel: View {
    let session: PlayerSession

    var body: some View {
        ScrollView {
            if let stream = session.stream {
                let source = stream.mediaSource
                Grid(alignment: .topLeading, horizontalSpacing: VelaTheme.Spacing.m, verticalSpacing: 10) {
                    row("播放方式", Self.methodTitle(stream))
                    if !stream.transcodeReasons.isEmpty {
                        row("转码原因", stream.transcodeReasons.map(Self.reasonTitle).joined(separator: "、"))
                    }
                    row("播放内核", session.controller.engine.kind == .mpv ? "MPV（libmpv，直放原文件）" : "系统（AVPlayer）")
                    row("容器", source.container?.uppercased())
                    row("视频", Self.videoSummary(source.videoStream))
                    row("音频", session.audioOptions.first { $0.index == session.selectedAudioIndex }.map(Self.trackSummary))
                    row("字幕", session.selectedSubtitleIndex.flatMap { index in
                        session.subtitleOptions.first { $0.index == index }.map(Self.trackSummary)
                    } ?? "关闭")
                    row("总码率", MediaFormat.bitrate(source.bitrate))
                    row("网速", session.controller.engine.networkThroughput.flatMap { MediaFormat.bitrate(Int($0)) })
                    row("已缓冲", Self.bufferAhead(session.controller.engine))
                    row("文件大小", MediaFormat.size(source.size))
                    row("文件", source.path)
                }
                .font(.subheadline)
                .textSelection(.enabled)
            } else {
                Text("非服务器条目，无媒体信息").foregroundStyle(.white.opacity(0.7))
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(key).foregroundStyle(.white.opacity(0.6))
                Text(value)
            }
        }
    }

    static func methodTitle(_ stream: ResolvedStream) -> String {
        guard stream.method == .transcode else { return "直接播放" }
        if stream.burnedSubtitleIndex != nil { return "服务器转码（烧录字幕）" }
        return PlaybackEngineChoice.reencodesVideo(reasons: stream.transcodeReasons) ? "服务器转码（HLS）" : "服务器转封装（HLS，视频无损）"
    }

    static func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "ContainerNotSupported": "容器不支持"
        case "VideoCodecNotSupported": "视频编码不支持"
        case "AudioCodecNotSupported": "音频编码不支持"
        case "SubtitleCodecNotSupported": "字幕需烧录"
        case "AudioIsExternal": "外挂音轨"
        case "SecondaryAudioNotSupported": "不支持多音轨"
        case "VideoProfileNotSupported": "视频配置不支持"
        case "VideoLevelNotSupported": "视频等级不支持"
        case "VideoResolutionNotSupported": "分辨率不支持"
        case "VideoBitDepthNotSupported": "位深不支持"
        case "VideoFramerateNotSupported": "帧率不支持"
        case "VideoRangeTypeNotSupported": "动态范围不支持"
        case "VideoCodecTagNotSupported": "视频编码标签不支持"
        case "RefFramesNotSupported": "参考帧数不支持"
        case "AnamorphicVideoNotSupported": "非方形像素不支持"
        case "InterlacedVideoNotSupported": "隔行视频不支持"
        case "AudioChannelsNotSupported": "声道数不支持"
        case "AudioProfileNotSupported": "音频配置不支持"
        case "AudioSampleRateNotSupported": "采样率不支持"
        case "AudioBitDepthNotSupported": "音频位深不支持"
        case "ContainerBitrateExceedsLimit": "码率超出限制"
        case "VideoBitrateNotSupported": "视频码率超出限制"
        case "AudioBitrateNotSupported": "音频码率超出限制"
        case "UnknownVideoStreamInfo": "视频流信息未知"
        case "UnknownAudioStreamInfo": "音频流信息未知"
        case "DirectPlayError": "直放失败"
        default: reason
        }
    }

    static func videoSummary(_ video: MediaStreamInfo?) -> String? {
        guard let video else { return nil }
        let size = video.width.flatMap { w in video.height.map { "\(w)×\($0)" } }
        let codec = [video.codec?.uppercased(), video.profile].compactMap { $0 }.joined(separator: " ")
        let fps = video.realFrameRate.map { String(format: "%.3g fps", $0) }
        return [size, codec.isEmpty ? nil : codec, video.videoRangeType, fps, MediaFormat.bitrate(video.bitRate)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// 当前位置之后已缓冲的时长；网速低于总码率且这里持续接近 0 即为带宽不足。
    static func bufferAhead(_ engine: any PlaybackEngine) -> String? {
        let ahead = engine.bufferedTime - engine.currentTime
        guard engine.bufferedTime > 0, ahead.isFinite else { return nil }
        return "\(Int(max(0, ahead))) 秒"
    }

    static func trackSummary(_ option: PlayerSession.TrackOption) -> String {
        [option.label.title, option.label.detailLine].compactMap { $0 }.joined(separator: "\n")
    }
}

/// 播放器内的时间格式：不足一小时为 mm:ss，否则 h:mm:ss。
enum PlayerTime {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let value = max(0, seconds)
        return Duration.seconds(value).formatted(.time(pattern: value >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
