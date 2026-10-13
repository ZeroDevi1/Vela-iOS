import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork
import VelaPlayer

/// 播放器面板（横屏 / iPad 贴右下角，iPhone 竖屏贴底，打开时隐藏控制层，点击面板外关闭；
/// macOS 从触发按钮弹出 popover，控制层保持显示，见 `PlayerPanelPopover`）。
enum PlayerPanel: String, Identifiable {
    case info, audio, subtitle, episodes, chapters
    /// 多段文件（CD1 / CD2 …）的各段，点选后原地切换。
    case parts
    /// 点按底部标题块打开：海报、简介、本季剧集与演职人员（Android 的节目信息面板）。
    case episodeInfo
    case subtitleStyle, subtitleDelay
    case quality

    var id: String { rawValue }

    /// 面板标题；单集信息自带大标题，返回 nil。
    var title: String? {
        switch self {
        case .info: "媒体信息"
        case .audio: "音轨"
        case .subtitle: "字幕"
        case .episodes: "剧集"
        case .parts: "分段"
        case .chapters: "章节"
        case .episodeInfo: nil
        case .subtitleStyle: "字幕缩放与位置"
        case .subtitleDelay: "字幕时间偏移"
        case .quality: "串流画质"
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
            // 侧边面板贴右下角：打开它的音轨 / 字幕 / 剧集按钮都在底部，手指不必移到屏幕顶部。
            ZStack(alignment: isBottomSheet ? .bottom : .bottomTrailing) {
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
                if let title = panel.title { Text(title).font(.headline) }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭面板")
            }
            content
        }
        .padding(VelaTheme.Spacing.l)
    }

    /// 音轨 / 字幕 / 分段通常只有几行：高度随内容，超过上限再滚动；剧集 / 章节 / 播放信息是长列表，直接用上限高度。
    /// 竖屏底部面板上限为屏高 60%，侧边面板上限为整屏高度。
    @ViewBuilder
    private func sized(_ card: some View, in size: CGSize) -> some View {
        let width = isBottomSheet ? min(600, size.width - 24) : min(400, size.width - 24)
        let maxHeight = isBottomSheet ? size.height * 0.6 : size.height - 24
        switch panel {
        case .audio, .subtitle, .subtitleStyle, .subtitleDelay, .quality, .parts:
            // 先限制最大高度，再按理想高度（内容高度）收缩。
            card
                .frame(width: width)
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
        case .info, .episodes, .chapters, .episodeInfo:
            card
                .frame(width: width)
                .frame(maxHeight: maxHeight, alignment: .top)
        }
    }

    private var content: some View {
        PlayerPanelContent(panel: panel, session: session, onClose: onClose)
    }
}

/// 各面板的内容，侧边面板与 macOS popover 共用。
private struct PlayerPanelContent: View {
    let panel: PlayerPanel
    let session: PlayerSession
    let onClose: () -> Void

    var body: some View {
        switch panel {
        case .info: PlaybackInfoPanel(session: session)
        case .audio: AudioPanel(session: session)
        case .subtitle: SubtitlePanel(session: session)
        case .episodes: EpisodesPanel(session: session, onPicked: onClose)
        case .parts: PartsPanel(session: session, onPicked: onClose)
        case .chapters: ChaptersPanel(session: session, onPicked: onClose)
        case .episodeInfo: EpisodeInfoPanel(session: session, onPicked: onClose)
        case .subtitleStyle: SubtitleStyleControls()
        case .subtitleDelay: SubtitleDelayControls(session: session)
        case .quality: QualityPanel(session: session, onPicked: onClose)
        }
    }
}

#if os(macOS)
/// macOS：面板以 popover 从触发按钮弹出（第 3.5 节「面板改为 popover」），不遮挡画面、不隐藏控制层；
/// 点按外部或 Esc 由系统关闭。打开期间固定显示控制层，否则控制层自动隐藏会移除锚点按钮、连带关闭 popover。
struct PlayerPanelPopover: View {
    let panel: PlayerPanel
    let session: PlayerSession
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            if let title = panel.title { Text(title).font(.headline) }
            PlayerPanelContent(panel: panel, session: session, onClose: onClose)
        }
        .padding(VelaTheme.Spacing.l)
        .frame(width: 360)
        .frame(maxHeight: Self.maxHeight(panel), alignment: .top)
        .fixedSize(horizontal: false, vertical: Self.fitsContent(panel))
        .onAppear { session.controller.pinControls(true) }
        .onDisappear { session.controller.pinControls(false) }
    }

    /// 与侧边面板相同的分类：短列表按内容高度，长列表用固定上限。
    private static func fitsContent(_ panel: PlayerPanel) -> Bool {
        switch panel {
        case .audio, .subtitle, .subtitleStyle, .subtitleDelay, .quality, .parts: true
        case .info, .episodes, .chapters, .episodeInfo: false
        }
    }

    private static func maxHeight(_ panel: PlayerPanel) -> CGFloat {
        fitsContent(panel) ? 480 : 560
    }
}
#endif

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
    /// 面板内切换到「在线搜索字幕」。
    @State private var isSearching = false

    var body: some View {
        if isSearching {
            RemoteSubtitleSearch(session: session) { isSearching = false }
        } else {
            trackList
        }
    }

    private var trackList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TrackRow(
                        label: TrackLabel(title: "关闭", details: [], flags: []),
                        isSelected: session.selectedSubtitleIndex == nil
                    ) { session.selectSubtitle(nil) }
                    if let local = session.localSubtitleName {
                        TrackRow(label: TrackLabel(title: local, details: ["本地文件"], flags: []), isSelected: true) {}
                    }
                    ForEach(session.subtitleOptions) { option in
                        TrackRow(
                            label: option.label,
                            note: option.requiresBurnIn ? "图形字幕，需服务器转码烧录" : nil,
                            isSelected: option.index == session.selectedSubtitleIndex
                        ) { session.selectSubtitle(option.index) }
                        .disabled(session.isSwitchingStream)
                    }
                }

                // 在线字幕只对服务器条目可用（由服务器的字幕插件搜索并保存）。
                if session.item != nil {
                    Button("在线搜索字幕", systemImage: "magnifyingglass") { isSearching = true }
                        .buttonStyle(.bordered)
                }

                if session.hasActiveSubtitle {
                    Divider().overlay(.white.opacity(0.3))
                    SubtitleDelayControls(session: session)
                    SubtitleStyleControls()
                }
            }
        }
        .scrollIndicators(.hidden)
        .tint(.white)
    }
}

/// 字幕时间偏移（字幕面板内与「更多 → 字幕时间偏移」共用）。
private struct SubtitleDelayControls: View {
    let session: PlayerSession

    var body: some View {
        if session.hasActiveSubtitle {
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
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        } else {
            // 时间偏移作用于客户端渲染的字幕（服务器 WebVTT / 本地文件），KSPlayer 读取的内嵌字幕不支持。
            Text("当前没有可调整时间的字幕").foregroundStyle(.white.opacity(0.7))
        }
    }

    private var delayText: String {
        let delay = session.subtitleDelay
        return delay == 0 ? "0 秒" : String(format: "%+.1f 秒", delay)
    }
}

/// 字幕字号与位置（全局设置，对所有字幕生效）。
private struct SubtitleStyleControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.playerPreferences
        VStack(spacing: VelaTheme.Spacing.m) {
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
        .tint(.white)
    }
}

// MARK: - 在线字幕

/// 在线搜索字幕：选语言（「字幕搜索记录」中的语言排在前面）→ 服务器搜索 → 点选后由服务器下载并自动选中。
private struct RemoteSubtitleSearch: View {
    let session: PlayerSession
    let onBack: () -> Void
    @Environment(AppModel.self) private var app

    @State private var language = ""
    @State private var results: [RemoteSubtitle]?
    @State private var isLoading = false
    @State private var downloadingID: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            HStack {
                Button("返回", systemImage: "chevron.backward", action: onBack)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                Picker("语言", selection: $language) {
                    ForEach(languageOptions, id: \.code) { Text($0.title).tag($0.code) }
                }
                .pickerStyle(.menu)
                Spacer(minLength: 0)
                Button("搜索") { search() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || language.isEmpty)
            }
            if isLoading {
                ProgressView("正在通过服务器搜索…").tint(.white).frame(maxWidth: .infinity)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if let results {
                if results.isEmpty {
                    Text("没有找到字幕。确认服务器已安装字幕插件（如 OpenSubtitles），或换一种语言。")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { row($0) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(.white)
        .onAppear {
            guard language.isEmpty else { return }
            let preferences = app.playerPreferences
            language = preferences.recentSubtitleSearchLanguages.first
                ?? (preferences.preferredSubtitleLanguage.isEmpty ? "chi" : preferences.preferredSubtitleLanguage)
        }
    }

    /// 最近搜索过的语言在前，其余按设置中的语言列表。
    private var languageOptions: [(code: String, title: String)] {
        let all = PlayerPreferences.languageOptions.filter { !$0.code.isEmpty }
        let recent = app.playerPreferences.recentSubtitleSearchLanguages.compactMap { code in all.first { $0.code == code } }
        return recent + all.filter { option in !recent.contains { $0.code == option.code } }
    }

    private func row(_ subtitle: RemoteSubtitle) -> some View {
        Button {
            download(subtitle)
        } label: {
            HStack(spacing: VelaTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subtitle.name ?? subtitle.id).font(.body).lineLimit(2)
                    let details = [
                        subtitle.providerName, subtitle.format?.uppercased(),
                        subtitle.downloadCount.map { "下载 \($0)" },
                        subtitle.isHashMatch == true ? "文件匹配" : nil
                    ].compactMap { $0 }
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                if downloadingID == subtitle.id { ProgressView().tint(.white) }
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
    }

    private func search() {
        isLoading = true
        error = nil
        Task {
            defer { isLoading = false }
            do {
                results = try await session.searchRemoteSubtitles(language: language)
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }

    private func download(_ subtitle: RemoteSubtitle) {
        downloadingID = subtitle.id
        error = nil
        Task {
            defer { downloadingID = nil }
            do {
                try await session.downloadRemoteSubtitle(subtitle)
                onBack()
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }

    /// 403 多为账号没有「字幕管理」权限，给出可操作的提示。
    private static func message(for error: Error) -> String {
        if case APIError.http(let status, _) = error, status == 403 {
            return "服务器拒绝：当前账号没有字幕管理权限（在服务器用户设置中开启）"
        }
        return error.localizedDescription
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

/// 多段文件的分段列表：当前段描边并标「正在播放」，点选其他段原地切换（与 Android 版播放列表一致）。
private struct PartsPanel: View {
    let session: PlayerSession
    let onPicked: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                ForEach(Array(session.parts.enumerated()), id: \.element.id) { index, part in
                    let isCurrent = part.id == session.item?.id
                    Button {
                        session.playEpisode(part)
                        onPicked()
                    } label: {
                        HStack(spacing: VelaTheme.Spacing.m) {
                            // 附加段多半没有自己的图片，退回第一段（主条目）的。
                            RemoteArtwork(
                                url: session.episodeImageURL(part) ?? session.parts.first.flatMap(session.episodeImageURL),
                                placeholderSymbol: "play.rectangle"
                            )
                            .frame(width: 128, height: 72)
                            .overlay(alignment: .bottom) {
                                if let fraction = part.playedFraction, !isCurrent {
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
                                Text("第 \(index + 1) 段")
                                    .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                HStack(spacing: 6) {
                                    if isCurrent { Text("正在播放") }
                                    if let runtime = MediaFormat.runtime(part.runTimeTicks) { Text(runtime) }
                                    if part.isPlayed { Image(systemName: "checkmark.circle.fill") }
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
                }
            }
        }
        .scrollIndicators(.hidden)
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

/// 媒体信息：按 串流 / 视频 / 音频 / 字幕 / 文件 分区，键在左、值右对齐（与 Android 媒体信息对话框一致）。
private struct PlaybackInfoPanel: View {
    let session: PlayerSession

    /// 分区标题色，与 Android 媒体信息对话框的蓝色标题相同。
    static let sectionTint = VelaTheme.accentLight

    var body: some View {
        ScrollView {
            if let stream = session.stream {
                let source = stream.mediaSource
                let engine = session.controller.engine
                VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                    section("串流") {
                        row("容器", [source.container?.uppercased(), MediaFormat.bitrate(source.bitrate).map { "（\($0)）" }]
                            .compactMap { $0 }.joined())
                        row("播放方式", Self.methodTitle(stream))
                        if !stream.transcodeReasons.isEmpty {
                            row("转码原因", stream.transcodeReasons.map(Self.reasonTitle).joined(separator: "、"))
                        }
                        row("播放内核", engine.kind.title)
                        row("网速", engine.networkThroughput.flatMap { MediaFormat.bitrate(Int($0)) })
                        row("已缓冲", Self.bufferAhead(engine))
                    }
                    if let video = source.videoStream {
                        section("视频") {
                            row("格式", Self.videoFormat(video))
                            row("参数", Self.videoParameters(video))
                            row("解码器", engine.kind == .avFoundation ? "VideoToolbox" : "FFmpeg + VideoToolbox")
                            row("分辨率", video.width.flatMap { w in video.height.map { "\(w)×\($0)" } })
                            row("动态范围", PlayerSession.dynamicRangeLabel(for: video) ?? video.videoRangeType)
                            row("HDR 元数据", (engine as? any HDRMetadataReporting)?.hdrStaticMetadata?.summary)
                        }
                    }
                    if let audio = source.audioStreams.first(where: { $0.index == session.selectedAudioIndex }) {
                        section("音频") {
                            row("音轨", audio.displayTitle ?? audio.codec?.uppercased())
                            row("采样率", audio.sampleRate.map { "\($0) Hz" })
                            row("码率", MediaFormat.bitrate(audio.bitRate))
                        }
                    }
                    section("字幕") {
                        row("字幕", session.localSubtitleName.map { "\($0)（本地文件）" }
                            ?? session.selectedSubtitleIndex.flatMap { index in
                                session.subtitleOptions.first { $0.index == index }.map(Self.trackSummary)
                            } ?? "关闭")
                    }
                    section("文件") {
                        row("大小", MediaFormat.size(source.size))
                        row("路径", source.path)
                    }
                }
                .font(.subheadline)
                .textSelection(.enabled)
            } else {
                Text("非服务器条目，无媒体信息").foregroundStyle(.white.opacity(0.7))
            }
        }
        .scrollIndicators(.hidden)
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(Self.sectionTint)
            rows()
        }
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: VelaTheme.Spacing.m) {
                Text(key).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: VelaTheme.Spacing.m)
                Text(value).multilineTextAlignment(.trailing)
            }
        }
    }

    /// 「4K HEVC」式的简述：按宽度归档分辨率（宽银幕片源高度小于标准值）。
    static func videoFormat(_ video: MediaStreamInfo) -> String? {
        let tier: String? = video.width.map { width in
            switch width {
            case 7600...: "8K"
            case 3800...: "4K"
            case 2500...: "1440p"
            case 1900...: "1080p"
            case 1260...: "720p"
            default: video.height.map { "\($0)p" } ?? "\(width)w"
            }
        }
        let text = [tier, video.codec?.uppercased()].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// 「Main 10 10bit 16 Mbps 60.000 fps」式的编码参数。
    static func videoParameters(_ video: MediaStreamInfo) -> String? {
        let parts = [
            video.profile,
            video.bitDepth.map { "\($0)bit" },
            MediaFormat.bitrate(video.bitRate),
            video.realFrameRate.map { String(format: "%.3f fps", $0) }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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

// MARK: - 串流画质

/// 视频码率上限：选择低于片源的码率时服务器转码（会重新编码视频，画质与码率相应下降）。
private struct QualityPanel: View {
    let session: PlayerSession
    let onPicked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text("选择视频码率上限，高于上限的片源由服务器转码").font(.caption).foregroundStyle(.white.opacity(0.7))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(PlayerSession.qualityOptions) { option in
                        let isSelected = option.bitrate == session.maxBitrateOverride
                        Button {
                            session.setMaxBitrate(option.bitrate)
                            onPicked()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.body.weight(isSelected ? .semibold : .regular))
                                    if option.bitrate == nil {
                                        Text("不限制码率").font(.caption).foregroundStyle(.white.opacity(0.6))
                                    }
                                }
                                Spacer()
                                if isSelected { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(isSelected ? .white.opacity(0.14) : .clear, in: .rect(cornerRadius: 12))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(session.isSwitchingStream)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - 单集信息

/// 单集信息（点按底部标题块打开，对应 Android 的节目信息面板）：海报、标题、日期、简介、本季剧集与演职人员。
private struct EpisodeInfoPanel: View {
    let session: PlayerSession
    let onPicked: () -> Void
    @State private var people: [ItemDetails.Person] = []

    var body: some View {
        if let item = session.item {
            ScrollView {
                VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
                    header(item)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineSpacing(4)
                    }
                    if !session.seasonEpisodes.isEmpty {
                        Text(item.parentIndexNumber.map { "来自第 \($0) 季" } ?? "本季剧集").font(.headline)
                        episodes(current: item)
                    }
                    if !people.isEmpty {
                        Text("演职人员").font(.headline)
                        cast
                    }
                }
            }
            .scrollIndicators(.hidden)
            .task(id: item.id) { people = await session.loadPeople() }
        }
    }

    private func header(_ item: MediaItem) -> some View {
        HStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
            RemoteArtwork(url: session.posterURL, placeholderSymbol: "film")
                .frame(width: 100, height: 150)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.title(for: item))
                    .font(.title3.weight(.bold))
                    .lineLimit(3)
                if let date = item.premiereDate {
                    Text(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let rating = item.communityRating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    /// 本季单集横向列表：缩略图左下角显示剩余或总时长（与 Android 一致），当前集描边。
    private func episodes(current: MediaItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                    ForEach(session.seasonEpisodes) { episode in
                        let isCurrent = episode.id == current.id
                        Button {
                            session.playEpisode(episode)
                            onPicked()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RemoteArtwork(url: session.episodeImageURL(episode), placeholderSymbol: "play.rectangle")
                                    .frame(width: 160, height: 90)
                                    .overlay(alignment: .bottomLeading) {
                                        if let badge = remainingBadge(episode, isCurrent: isCurrent) {
                                            Text(badge)
                                                .font(.caption2.weight(.semibold).monospacedDigit())
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(.black.opacity(0.55), in: .capsule)
                                                .padding(6)
                                        }
                                    }
                                    .clipShape(.rect(cornerRadius: 10))
                                    .overlay {
                                        if isCurrent { RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2) }
                                    }
                                Text("\(episode.indexNumber.map { "\($0)." } ?? "")\(episode.name)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 160, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                        .id(episode.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current.id, anchor: .leading) }
        }
    }

    private var cast: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                ForEach(people.prefix(30)) { person in
                    VStack(spacing: 6) {
                        RemoteArtwork(url: session.personImageURL(person), placeholderSymbol: "person.fill")
                            .frame(width: 96, height: 128)
                            .clipShape(.rect(cornerRadius: 10))
                        Text(person.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 96)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// 当前集按播放位置算剩余；有进度的集按服务器进度算剩余；其余显示总时长。
    private func remainingBadge(_ episode: MediaItem, isCurrent: Bool) -> String? {
        let total = episode.runTimeTicks.map(Ticks.seconds)
        if isCurrent {
            let engine = session.controller.engine
            guard engine.duration > 0 else { return total.map(Self.duration) }
            return "剩余：" + Self.duration(engine.duration - engine.currentTime)
        }
        if let total, let position = episode.playbackPositionTicks.map(Ticks.seconds), position > 0, !episode.isPlayed {
            return "剩余：" + Self.duration(total - position)
        }
        return total.map(Self.duration)
    }

    /// 「46分17秒」「1小时05分」式时长。
    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        let hours = value / 3600, minutes = value % 3600 / 60, secs = value % 60
        return hours > 0 ? String(format: "%d小时%02d分", hours, minutes) : "\(minutes)分\(String(format: "%02d", secs))秒"
    }

    static func title(for item: MediaItem) -> String {
        guard item.kind == .episode, let episode = item.indexNumber else { return item.name }
        let season = item.parentIndexNumber.map { "S\($0)" } ?? ""
        return "\(season)E\(episode)：\(item.name)"
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
