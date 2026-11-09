import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

// MARK: - 播放源选择

/// 版本 / 音轨 / 字幕选择卡片。选择结果随播放请求传给播放器。
struct SourceSelectionCard: View {
    @Bindable var model: DetailModel

    var body: some View {
        if let source = model.selectedSource {
            VStack(alignment: .leading, spacing: 0) {
                row(icon: "play.rectangle.on.rectangle") {
                    if model.sourceOptions.count > 1 {
                        VersionSelectionMenu(model: model)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name ?? model.item.name).lineLimit(1)
                            Text(MediaFormat.sourceSummary(source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !source.audioStreams.isEmpty {
                    Divider().padding(.leading, 44)
                    row(icon: "music.note") {
                        TrackSelectionMenu(
                            title: "音轨",
                            streams: source.audioStreams,
                            selection: $model.selectedAudioIndex
                        )
                    }
                }
                if !source.subtitleStreams.isEmpty {
                    Divider().padding(.leading, 44)
                    row(icon: "captions.bubble") {
                        TrackSelectionMenu(
                            title: "字幕",
                            streams: source.subtitleStreams,
                            selection: $model.selectedSubtitleIndex,
                            offValue: -1
                        )
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.vertical, 4)
            .background(.regularMaterial, in: .rect(cornerRadius: VelaTheme.Radius.panel))
        }
    }

    private func row<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VelaTheme.Spacing.m)
        .padding(.vertical, 10)
    }
}

/// 版本选择：名称为主标题、「1080p H264 · 2.3 GB」为副标题。包含客户端合并进来的条目的版本。
private struct VersionSelectionMenu: View {
    @Bindable var model: DetailModel

    var body: some View {
        let options = model.sourceOptions
        Menu {
            ForEach(options) { option in
                Toggle(isOn: Binding(
                    get: { model.selectedSource?.id == option.id },
                    set: { if $0 { select(option.id) } }
                )) {
                    Text(title(option))
                    Text(MediaFormat.sourceSummary(option.source))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let current = options.first(where: { $0.id == model.selectedSource?.id }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(current)).lineLimit(1)
                        Text(MediaFormat.sourceSummary(current.source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text("\(options.count) 个版本").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("版本")
    }

    private func select(_ id: String) {
        model.selectedSourceID = id
        model.resetSelections()
    }

    /// 媒体源没有名称时用文件名区分合并进来的条目。
    private func title(_ option: DetailModel.SourceOption) -> String {
        if let name = option.source.name, !name.isEmpty { return name }
        if let path = option.source.path { return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        return option.item.name
    }
}

/// 音轨 / 字幕选择菜单。中文语言名作主标题，服务器原始标题与采样率、码率、标记作副标题，
/// 与播放器面板共用 `TrackLabelFormatter`。
///
/// 不用 `Picker`：菜单式 Picker 的选项只显示第一个 `Text`，副标题会被丢掉；`Toggle` 菜单项支持标题 + 副标题并带勾选。
struct TrackSelectionMenu: View {
    let title: String
    let streams: [MediaStreamInfo]
    @Binding var selection: Int?
    /// 提供时显示「关闭」选项，选中值为该值（字幕为 -1）。
    var offValue: Int?

    var body: some View {
        Menu {
            if let offValue {
                Toggle(isOn: binding(for: offValue)) { Text("关闭") }
            }
            ForEach(streams, id: \.index) { stream in
                let text = Self.texts(for: stream)
                Toggle(isOn: binding(for: stream.index)) {
                    Text(text.primary)
                    Text(text.secondary)
                }
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.primary).lineLimit(1)
                    if let secondary = current.secondary {
                        Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(current.primary)
    }

    private var current: (primary: String, secondary: String?) {
        guard let selection, selection != offValue,
              let stream = streams.first(where: { $0.index == selection }) else {
            return (offValue != nil ? "关闭" : "默认", nil)
        }
        let text = Self.texts(for: stream)
        return (text.primary, text.secondary)
    }

    private func binding(for value: Int) -> Binding<Bool> {
        Binding(get: { selection == value }, set: { if $0 { selection = value } })
    }

    /// 主标题：中文语言名（无法识别时用原始标题）；副标题：原始标题、参数、标记，图形字幕注明需转码。
    static func texts(for stream: MediaStreamInfo) -> (primary: String, secondary: String) {
        let label = stream.trackLabel ?? TrackLabel(title: "轨道 \(stream.index)")
        var secondary = [label.title] + label.details + label.flags.map(\.rawValue)
        if label.languageName == nil { secondary.removeFirst() }
        if stream.type == "Subtitle", !stream.isTextSubtitle { secondary.append(stream.isEmbeddedPGS ? "图形字幕" : "需转码") }
        return (label.languageName ?? label.title, secondary.joined(separator: " · "))
    }
}

// MARK: - 单集

/// 横向单集列表，自动滚动到当前集。超过 `EpisodePaging.pageSize` 集时按区间分页（长篇动画常有数百集，
/// 只靠横滑在 iPad / Mac 上很难定位），初始区间为当前集所在的一段。
struct EpisodeShelf: View {
    let title: String
    let episodes: [MediaItem]
    let currentID: String
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact
    @State private var rangeIndex: Int?

    private var paged: Bool { episodes.count > EpisodePaging.pageSize }
    private var currentRange: Int {
        rangeIndex ?? (episodes.firstIndex { $0.id == currentID } ?? 0) / EpisodePaging.pageSize
    }
    private var visible: ArraySlice<MediaItem> {
        paged ? episodes[EpisodePaging.range(currentRange, total: episodes.count)] : episodes[...]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text(title).font(.title3.weight(.semibold)).velaPageMargin()
            if paged {
                EpisodeRangeBar(episodes: episodes, selected: currentRange, compact: isCompact) { rangeIndex = $0 }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(visible) { episode in
                            NavigationLink(value: episode) {
                                LandscapeCard(
                                    title: "\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)",
                                    subtitle: MediaFormat.runtime(episode.runTimeTicks),
                                    imageURL: app.imageURL(for: episode, kind: .primary, maxWidth: 480),
                                    progress: episode.playedFraction,
                                    width: isCompact ? 220 : 280
                                )
                                .overlay(alignment: .topLeading) {
                                    if episode.id == currentID {
                                        RoundedRectangle(cornerRadius: VelaTheme.Radius.card)
                                            .stroke(.white, lineWidth: 2)
                                            .frame(height: (isCompact ? 220 : 280) * 9 / 16)
                                    }
                                }
                                .overlay(alignment: .topTrailing) { PlayedMark(played: episode.isPlayed) }
                            }
                            .buttonStyle(.plain)
                            .itemContextMenu(episode)
                            .id(episode.id)
                        }
                    }
                    .velaPageMargin()
                }
                .velaHideHorizontalScrollIndicators()
                .onAppear { proxy.scrollTo(currentID, anchor: .center) }
                .velaHorizontalPaging()
                // 换区间后回到该段开头（当前集所在的一段回到当前集）。
                .onChange(of: rangeIndex) {
                    let target = visible.contains { $0.id == currentID } ? currentID : visible.first?.id
                    // 等新区间的卡片布局完成后再滚动，否则目标 id 尚不存在。
                    if let target { Task { @MainActor in proxy.scrollTo(target, anchor: visible.first?.id == target ? .leading : .center) } }
                }
            }
        }
    }
}

/// 单集区间选择（「1 · 30」「31 · 60」…）：iOS 为横向滚动的胶囊，选中段自动滚入可见区域；macOS 为翻段按钮 + 区间菜单。
/// 标签用集号（缺失时显示「–」），与 Forward 一致；iPad / Mac 详情页与单集页的「更多来自」共用。
struct EpisodeRangeBar<Trailing: View>: View {

    let episodes: [MediaItem]
    let selected: Int
    var compact = false
    let select: (Int) -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            #if os(macOS)
            macPicker
            Spacer(minLength: 0)
            #else
            capsules
            #endif
            trailing
        }
        .velaPageMargin()
    }

    private var count: Int { EpisodePaging.count(episodes.count) }

    private func title(_ index: Int) -> String {
        let range = EpisodePaging.range(index, total: episodes.count)
        return "\(label(episodes[range.lowerBound])) · \(label(episodes[range.upperBound - 1]))"
    }

    #if os(macOS)
    /// Mac 没有触屏，横滑的胶囊难以操作：改为「上一段 / 区间菜单 / 下一段」，几十个区间也只占一行。
    private var macPicker: some View {
        HStack(spacing: VelaTheme.Spacing.s) {
            Button("上一段", systemImage: "chevron.left") { select(selected - 1) }
                .disabled(selected <= 0)
            Menu {
                ForEach(0..<count, id: \.self) { index in
                    Toggle(isOn: Binding(get: { index == selected }, set: { if $0 { select(index) } })) {
                        Text(title(index))
                    }
                }
            } label: {
                Text("第 \(title(selected)) 集")
                    .font((compact ? Font.subheadline : .headline).monospacedDigit())
            }
            .menuStyle(.button)
            .fixedSize()
            Button("下一段", systemImage: "chevron.right") { select(selected + 1) }
                .disabled(selected >= count - 1)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(compact ? .regular : .large)
    }
    #else
    private var capsules: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: VelaTheme.Spacing.s) {
                    ForEach(0..<count, id: \.self) { index in
                        Button { select(index) } label: {
                            Text(title(index))
                                .font((compact ? Font.subheadline : .headline).monospacedDigit())
                                .padding(.horizontal, compact ? 14 : 22)
                                .padding(.vertical, compact ? 8 : 12)
                                .background(index == selected ? Color.black.opacity(0.75) : Color.white.opacity(0.08), in: .capsule)
                                .foregroundStyle(index == selected ? .white : .white.opacity(0.6))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .velaHideHorizontalScrollIndicators()
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { withAnimation { proxy.scrollTo(selected, anchor: .center) } }
        }
    }
    #endif

    private func label(_ episode: MediaItem) -> String {
        episode.indexNumber.map(String.init) ?? "–"
    }

}

/// 单集分段：每段 30 集（与 Forward 一致）。
enum EpisodePaging {
    static let pageSize = 30

    static func count(_ total: Int) -> Int { (total + pageSize - 1) / pageSize }

    static func range(_ index: Int, total: Int) -> Range<Int> {
        let start = min(index * pageSize, total)
        return start..<min(start + pageSize, total)
    }
}

extension EpisodeRangeBar where Trailing == EmptyView {
    init(episodes: [MediaItem], selected: Int, compact: Bool = false, select: @escaping (Int) -> Void) {
        self.init(episodes: episodes, selected: selected, compact: compact, select: select) { EmptyView() }
    }
}

struct PlayedMark: View {
    let played: Bool

    var body: some View {
        if played {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, VelaTheme.accentDeep)
                .font(.title3)
                .padding(6)
                .accessibilityLabel("已看")
        }
    }
}

/// 季页面：单集超过 50 集时按区间分页（例如 1-50、51-100），避免长篇番剧一次渲染上千行。
struct SeasonDetailView: View {
    let route: SeasonRoute
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var episodes: LoadState<[MediaItem]> = .idle
    @State private var rangeIndex = 0
    @State private var showsSeasonDownload = false

    /// 每段集数，与 Android 一致（1-20、21-40 …）。
    private static let pageSize = 20

    var body: some View {
        content
            .navigationTitle("\(route.series.name) · \(route.season.name)")
            .toolbar {
                Button("下载本季", systemImage: "arrow.down.circle") { showsSeasonDownload = true }
            }
            .sheet(isPresented: $showsSeasonDownload) {
                SeasonDownloadSheet(
                    seriesID: route.series.id, seasonID: route.season.id,
                    title: "下载 \(route.season.name)", serverID: route.series.serverID
                )
            }
            .task { await load() }
    }

    #if os(macOS)
    /// Mac 用网格一次列出全部单集（第 3.5 节：需要总览的选集不用横滑 / 分段），悬停显示播放与更多按钮。
    @ViewBuilder
    private var content: some View {
        switch episodes {
        case .loaded(let all):
            ScrollView {
                VStack(alignment: .leading, spacing: VelaTheme.Spacing.l) {
                    header(all)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.macCardWidth), spacing: VelaTheme.Spacing.l)], spacing: VelaTheme.Spacing.l) {
                        ForEach(all) { episode in
                            NavigationLink(value: episode) {
                                LandscapeCard(
                                    title: "\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)",
                                    subtitle: MediaFormat.runtime(episode.runTimeTicks),
                                    imageURL: app.imageURL(for: episode, kind: .primary, maxWidth: 480),
                                    progress: episode.playedFraction,
                                    width: Self.macCardWidth
                                )
                                .overlay(alignment: .topLeading) { PlayedMark(played: episode.isPlayed) }
                            }
                            .buttonStyle(.plain)
                            .itemContextMenu(episode)
                        }
                    }
                }
                .padding(.vertical, VelaTheme.Spacing.l)
                .velaPageMargin()
            }
        case .failed(let message):
            LoadFailureView(message: message) { Task { await load() } }
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static let macCardWidth: CGFloat = 240
    #else
    private var content: some View {
        List {
            switch episodes {
            case .loaded(let all):
                Section {
                    header(all)
                }
                .listRowBackground(Color.clear)
                if all.count > Self.pageSize {
                    Section {
                        ScrollView(.horizontal) {
                            HStack(spacing: VelaTheme.Spacing.s) {
                                ForEach(0..<pageCount(all), id: \.self) { index in
                                    let range = pageRange(index, total: all.count)
                                    Button("\(range.lowerBound + 1)-\(range.upperBound)") { rangeIndex = index }
                                        .buttonStyle(.bordered)
                                        .tint(index == rangeIndex ? VelaTheme.accent : nil)
                                        .fontWeight(index == rangeIndex ? .bold : .regular)
                                }
                            }
                        }
                        .velaHideHorizontalScrollIndicators()
                        .velaHorizontalPaging()
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(all[pageRange(rangeIndex, total: all.count)]) { episode in
                        NavigationLink(value: episode) { EpisodeRow(episode: episode) }
                            .itemContextMenu(episode)
                            .swipeActions(edge: .leading) {
                                Button("播放", systemImage: "play.fill") { playMedia(.item(episode)) }.tint(VelaTheme.accentDeep)
                            }
                    }
                }
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
    #endif

    /// 季名、集数与播放按钮（播放第一个未看完的单集，全部看完时从第一集开始）。
    private func header(_ all: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text(route.season.name).font(.title2.weight(.bold))
            Text("\(all.count) 集").foregroundStyle(.secondary)
            if let target = all.first(where: { !$0.isPlayed }) ?? all.first {
                Button { playMedia(.item(target)) } label: {
                    Label(target.episodeLabel.map { "播放 \($0)" } ?? "播放", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.large)
            }
        }
    }

    private func pageCount(_ items: [MediaItem]) -> Int { (items.count + Self.pageSize - 1) / Self.pageSize }

    private func pageRange(_ index: Int, total: Int) -> Range<Int> {
        let start = min(index * Self.pageSize, total)
        return start..<min(start + Self.pageSize, total)
    }

    private func load() async {
        guard let client = app.client(forServerID: route.series.serverID) else { return }
        episodes = .loading
        let result = await capture { try await client.episodes(seriesID: route.series.id, seasonID: route.season.id) }
        episodes = LoadState(result)
        // 默认定位到第一个未看完的区间。
        if case .success(let all) = result, let firstUnplayed = all.firstIndex(where: { !$0.isPlayed }) {
            rangeIndex = firstUnplayed / Self.pageSize
        }
    }
}

private struct EpisodeRow: View {
    let episode: MediaItem
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
            RemoteArtwork(url: app.imageURL(for: episode, kind: .primary, maxWidth: 400), placeholderSymbol: "play.rectangle")
                .frame(width: 150, height: 84)
                .overlay(alignment: .bottom) {
                    if let fraction = episode.playedFraction {
                        ProgressView(value: fraction).tint(VelaTheme.accent).padding(4)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { PlayedMark(played: episode.isPlayed) }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)")
                    .font(.headline)
                    .lineLimit(2)
                if let runtime = MediaFormat.runtime(episode.runTimeTicks) {
                    Text(runtime).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        // 简介放在缩略图下方整行显示（与 Android 一致），比挤在右侧能显示更多内容。
        if let overview = episode.overview, !overview.isEmpty {
            Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }
        }
    }
}

// MARK: - 多段文件

/// 多段文件（CD1 / CD2 …）：点任意一段播放，播放器会按顺序衔接后续各段。
struct PartsShelf: View {
    let parts: [MediaItem]
    /// 第一段（主条目）要播放的版本；其余段是独立条目，用各自的默认源。
    let sourceID: String?
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        let indexed = Array(parts.enumerated()).map { IndexedPart(index: $0.offset, item: $0.element) }
        MediaShelf("分段（\(parts.count)）", items: indexed) { part in
            Button {
                playMedia(.item(part.item, options: .init(
                    mediaSourceID: part.index == 0 ? sourceID : nil,
                    partIDs: parts.map(\.id),
                    partsSourceID: sourceID
                )))
            } label: {
                LandscapeCard(
                    title: "第 \(part.index + 1) 段",
                    subtitle: [MediaFormat.runtime(part.item.runTimeTicks), part.item.isPlayed ? "已看" : nil].compactMap { $0 }.joined(separator: " · "),
                    imageURL: app.imageURL(for: part.item, kind: .primary, maxWidth: 480)
                        ?? app.imageURL(for: parts[0], kind: .backdrop, maxWidth: 480),
                    progress: part.item.playedFraction,
                    width: isCompact ? 200 : 260
                )
            }
            .buttonStyle(.plain)
        }
    }

    private struct IndexedPart: Identifiable {
        var index: Int
        var item: MediaItem
        var id: String { item.id }
    }
}

// MARK: - 预告片和花絮

/// 本地预告片、远程预告片（交给系统打开）与花絮。全部为空时不显示。
struct ExtrasShelf: View {
    let trailers: [MediaItem]
    let remoteTrailers: [ItemDetails.RemoteTrailer]
    let features: [MediaItem]
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.openURL) private var openURL
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        // 有本地预告片时不再列出远程链接，避免同一支预告片出现两次。
        let remote = trailers.isEmpty ? remoteTrailers : []
        if !trailers.isEmpty || !remote.isEmpty || !features.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("预告片和花絮").font(.title3.weight(.semibold)).velaPageMargin()
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(trailers) { card($0, badge: "预告片") }
                        ForEach(remote) { trailer in
                            Button { openURL(trailer.url) } label: {
                                LandscapeCard(
                                    title: trailer.name ?? "预告片",
                                    subtitle: trailer.url.host().map { "在线预告片 · \($0)" } ?? "在线预告片",
                                    imageURL: Self.youTubeThumbnail(trailer.url),
                                    width: cardWidth
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(features) { card($0, badge: "花絮") }
                    }
                    .velaPageMargin()
                }
                .velaHideHorizontalScrollIndicators()
                .velaHorizontalPaging()
            }
        }
    }

    private var cardWidth: CGFloat { isCompact ? 220 : 280 }

    /// YouTube 预告片的封面图（`img.youtube.com/vi/<id>/hqdefault.jpg`）；其他站点没有可推导的封面，返回 nil。
    /// 支持 `youtube.com/watch?v=`、`youtu.be/<id>`、`youtube.com/embed/<id>` 三种链接。
    static func youTubeThumbnail(_ url: URL) -> URL? {
        guard let host = url.host()?.lowercased() else { return nil }
        let id: String?
        if host.hasSuffix("youtu.be") {
            id = url.pathComponents.dropFirst().first
        } else if host.hasSuffix("youtube.com") {
            if url.pathComponents.count > 2, ["embed", "shorts"].contains(url.pathComponents[1]) {
                id = url.pathComponents[2]
            } else {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            }
        } else {
            id = nil
        }
        guard let id, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
    }

    private func card(_ item: MediaItem, badge: String) -> some View {
        Button { playMedia(.item(item)) } label: {
            LandscapeCard(
                title: item.name,
                subtitle: [badge, MediaFormat.runtime(item.runTimeTicks)].compactMap { $0 }.joined(separator: " · "),
                imageURL: app.imageURL(for: item, kind: .primary, maxWidth: 480),
                progress: item.playedFraction,
                width: cardWidth
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 章节 / 演职员

/// 章节：16:9 缩略图叠「章节名 / 起始时间」与播放图标（与 Forward 一致），点按从该章节起播。
struct ChapterShelf: View {
    let item: MediaItem
    let client: MediaServerClient?
    /// 从指定秒数起播；由详情页提供，沿用已选的版本 / 音轨 / 字幕。
    let play: (TimeInterval) -> Void
    @Environment(\.velaLayout) private var layout

    private var chapters: [(offset: Int, element: MediaChapter)] {
        Array(item.chapters.enumerated()).filter { $0.element.marker == .chapter }
    }

    private var cardWidth: CGFloat { layout.isWide ? 250 : 200 }

    var body: some View {
        if chapters.count > 1 {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("章节").font(.title3.weight(.semibold)).velaPageMargin()
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(chapters, id: \.offset) { index, chapter in
                            Button { play(chapter.start) } label: { card(index: index, chapter: chapter) }
                                .buttonStyle(.plain)
                        }
                    }
                    .velaPageMargin()
                }
                .velaHideHorizontalScrollIndicators()
                .velaHorizontalPaging()
            }
        }
    }

    private func card(index: Int, chapter: MediaChapter) -> some View {
        RemoteArtwork(
            url: client?.chapterImageURL(itemID: item.id, index: index, chapter: chapter, maxWidth: 480),
            placeholderSymbol: "list.bullet.rectangle"
        )
        .frame(width: cardWidth, height: cardWidth * 9 / 16)
        .overlay {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 1) {
                Text(chapter.name ?? "章节 \(index + 1)").font(.caption.weight(.semibold)).lineLimit(1)
                Text(Duration.seconds(chapter.start).formatted(.time(pattern: chapter.start >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(10)
        }
        .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
        .velaCardHover()
        .accessibilityElement(children: .combine)
        .accessibilityHint("从该章节开始播放")
    }
}

struct CastShelf: View {
    let people: [ItemDetails.Person]
    let client: MediaServerClient?
    let serverID: String

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("演职人员").font(.title3.weight(.semibold)).velaPageMargin()
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(people.prefix(40)) { person in
                            NavigationLink(value: PersonRoute(serverID: serverID, person: person)) {
                            VStack(alignment: .leading, spacing: 2) {
                                RemoteArtwork(url: client?.personImageURL(person, maxWidth: 300), placeholderSymbol: "person.fill")
                                    .frame(width: 104, height: 138)
                                    .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                                Text(person.name).font(.subheadline).lineLimit(1)
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(Self.typeName(person.type)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(width: 104, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .velaPageMargin()
                }
                .velaHideHorizontalScrollIndicators()
                .velaHorizontalPaging()
            }
        }
    }

    static func typeName(_ type: String?) -> String {
        switch type {
        case "Actor": "演员"
        case "GuestStar": "客串"
        case "Director": "导演"
        case "Writer": "编剧"
        case "Producer": "制片"
        case "Composer": "作曲"
        default: type ?? ""
        }
    }
}

// MARK: - 媒体信息

struct MediaInfoSection: View {
    let details: ItemDetails
    let source: MediaSourceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
            Text("媒体信息").font(.title3.weight(.semibold)).velaPageMargin()

            // 与 Android 一致：条目标题、文件路径、日期、容器 / 大小 / 时长、入库时间逐行左对齐，下面是各媒体流卡片。
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.title(for: details.item)).font(.headline)
                if let path = source.path ?? details.path {
                    Text(path).textSelection(.enabled)
                }
                if let date = details.item.premiereDate {
                    Text(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                }
                Text([
                    source.container?.uppercased(),
                    MediaFormat.size(source.size),
                    MediaFormat.runtime(source.runTimeTicks ?? details.item.runTimeTicks)
                ].compactMap { $0 }.joined(separator: "  "))
                if let added = details.dateCreated {
                    Text("添加于：" + added.formatted(date: .numeric, time: .shortened))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .velaPageMargin()

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                    ForEach(source.mediaStreams, id: \.index) { stream in
                        StreamCard(stream: stream)
                    }
                }
                .velaPageMargin()
            }
            .velaHideHorizontalScrollIndicators()
            .velaHorizontalPaging()
        }
    }

    /// 单集「S01E01 - 标题」，其余为名称。
    static func title(for item: MediaItem) -> String {
        guard let label = item.episodeLabel else { return item.name }
        return "\(label) - \(item.name)"
    }
}

/// 单条媒体流卡片；`title` / `symbol` / `rows` 也供宽屏三列媒体信息复用。
struct StreamCard: View {
    let stream: MediaStreamInfo

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Label(title, systemImage: symbol).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: VelaTheme.Spacing.m, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { key, value in
                    GridRow {
                        Text(key).foregroundStyle(.secondary)
                        Text(value).lineLimit(2)
                    }
                }
            }
            .font(.caption)
        }
        .padding(VelaTheme.Spacing.m)
        .frame(width: 260, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: VelaTheme.Radius.panel))
    }

    var title: String {
        switch stream.type {
        case "Video": "视频"
        case "Audio": "音频"
        case "Subtitle": "字幕"
        default: stream.type
        }
    }

    var symbol: String {
        switch stream.type {
        case "Video": "video"
        case "Audio": "speaker.wave.2"
        case "Subtitle": "captions.bubble"
        default: "doc"
        }
    }

    var rows: [(String, String)] {
        var rows: [(String, String?)] = [
            ("标题", stream.displayTitle),
            ("内嵌标题", stream.title),
            ("语言", stream.language),
            ("编码", stream.codec.map { [$0, stream.codecTag].compactMap { $0 }.joined(separator: " / ") })
        ]
        switch stream.type {
        case "Video":
            rows += [
                ("分辨率", stream.width.flatMap { w in stream.height.map { "\(w)x\($0)" } }),
                ("帧率", stream.realFrameRate.map { String(format: "%.3f", $0) }),
                ("码率", MediaFormat.bitrate(stream.bitRate)),
                // Emby 不返回 VideoRangeType，与播放器信息面板共用推断（ExtendedVideoType / ColorTransfer）。
                ("动态范围", PlayerSession.dynamicRangeLabel(for: stream) ?? stream.videoRangeType),
                ("传递函数", stream.colorTransfer),
                ("配置", stream.profile),
                ("等级", stream.level.map { String(format: "%.1f", $0) }),
                ("长宽比", stream.aspectRatio),
                ("位深", stream.bitDepth.map(String.init)),
                ("像素格式", stream.pixelFormat),
                ("隔行", stream.isInterlaced.map { $0 ? "是" : "否" })
            ]
        case "Audio":
            rows += [
                ("布局", stream.channelLayout),
                ("声道", stream.channels.map(String.init)),
                ("码率", MediaFormat.bitrate(stream.bitRate)),
                ("采样率", stream.sampleRate.map { "\($0) Hz" })
            ]
        default:
            rows += [("强制", stream.isForced.map { $0 ? "是" : "否" })]
        }
        rows += [
            ("外部", stream.isExternal.map { $0 ? "是" : "否" }),
            ("默认", stream.isDefault.map { $0 ? "是" : "否" })
        ]
        return rows.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } }
    }
}

// MARK: - 导航目的地

extension View {
    /// 注册详情相关的导航目的地。各标签页的 NavigationStack 统一调用，保证从任意入口进入的详情行为一致。
    func detailDestinations() -> some View {
        self
            .navigationDestination(for: MediaItem.self) { ItemDetailView(item: $0) }
            .navigationDestination(for: SeasonRoute.self) { SeasonDetailView(route: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonDetailView(route: $0) }
            .navigationDestination(for: PersonWorksRoute.self) { PersonWorksView(route: $0) }
            .navigationDestination(for: DetailTagRoute.self) { DetailTagItemsView(route: $0) }
    }
}
