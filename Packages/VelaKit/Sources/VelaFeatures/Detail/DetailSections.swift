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
            .glassEffect(.regular, in: .rect(cornerRadius: VelaTheme.Radius.panel))
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
private struct TrackSelectionMenu: View {
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
        if stream.type == "Subtitle", !stream.isTextSubtitle { secondary.append("需转码") }
        return (label.languageName ?? label.title, secondary.joined(separator: " · "))
    }
}

// MARK: - 单集

/// 横向单集列表，自动滚动到当前集。
struct EpisodeShelf: View {
    let title: String
    let episodes: [MediaItem]
    let currentID: String
    @Environment(AppModel.self) private var app
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(episodes) { episode in
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
                            .id(episode.id)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
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

    /// 每段集数，与 Android 一致（1-20、21-40 …）。
    private static let pageSize = 20

    var body: some View {
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
                                        .buttonStyle(.glass)
                                        .tint(index == rangeIndex ? VelaTheme.accent : nil)
                                        .fontWeight(index == rangeIndex ? .bold : .regular)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(all[pageRange(rangeIndex, total: all.count)]) { episode in
                        NavigationLink(value: episode) { EpisodeRow(episode: episode) }
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
        .navigationTitle("\(route.series.name) · \(route.season.name)")
        .task { await load() }
    }

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
                .buttonStyle(.glassProminent)
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
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        let indexed = Array(parts.enumerated()).map { IndexedPart(index: $0.offset, item: $0.element) }
        MediaShelf("分段（\(parts.count)）", items: indexed) { part in
            Button {
                playMedia(.item(part.item, options: .init(partIDs: parts.map(\.id))))
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
                Text("预告片和花絮").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(trailers) { card($0, badge: "预告片") }
                        ForEach(remote) { trailer in
                            Button { openURL(trailer.url) } label: {
                                LandscapeCard(
                                    title: trailer.name ?? "预告片",
                                    subtitle: trailer.url.host().map { "在线预告片 · \($0)" } ?? "在线预告片",
                                    imageURL: nil,
                                    width: cardWidth
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(features) { card($0, badge: "花絮") }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var cardWidth: CGFloat { isCompact ? 220 : 280 }

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

struct ChapterShelf: View {
    let item: MediaItem
    let client: MediaServerClient?
    @Environment(\.playMedia) private var playMedia

    private var chapters: [(offset: Int, element: MediaChapter)] {
        Array(item.chapters.enumerated()).filter { $0.element.marker == .chapter }
    }

    var body: some View {
        if chapters.count > 1 {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("章节").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                        ForEach(chapters, id: \.offset) { index, chapter in
                            VStack(alignment: .leading, spacing: 4) {
                                RemoteArtwork(
                                    url: client?.chapterImageURL(itemID: item.id, index: index, chapter: chapter, maxWidth: 400),
                                    placeholderSymbol: "list.bullet.rectangle"
                                )
                                .frame(width: 200, height: 112)
                                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                                Text(chapter.name ?? "章节 \(index + 1)").font(.subheadline).lineLimit(1)
                                Text(Duration.seconds(chapter.start).formatted(.time(pattern: chapter.start >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 200, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct CastShelf: View {
    let people: [ItemDetails.Person]
    let client: MediaServerClient?
    let serverID: String

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
                Text("演职人员").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)
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
                    .padding(.horizontal, VelaTheme.Spacing.l)
                }
                .scrollIndicators(.hidden)
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
            Text("媒体信息").font(.title3.weight(.semibold)).padding(.horizontal, VelaTheme.Spacing.l)

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
            .padding(.horizontal, VelaTheme.Spacing.l)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                    ForEach(source.mediaStreams, id: \.index) { stream in
                        StreamCard(stream: stream)
                    }
                }
                .padding(.horizontal, VelaTheme.Spacing.l)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// 单集「S01E01 - 标题」，其余为名称。
    static func title(for item: MediaItem) -> String {
        guard let label = item.episodeLabel else { return item.name }
        return "\(label) - \(item.name)"
    }
}

private struct StreamCard: View {
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
        .glassEffect(.regular, in: .rect(cornerRadius: VelaTheme.Radius.panel))
    }

    private var title: String {
        switch stream.type {
        case "Video": "视频"
        case "Audio": "音频"
        case "Subtitle": "字幕"
        default: stream.type
        }
    }

    private var symbol: String {
        switch stream.type {
        case "Video": "video"
        case "Audio": "speaker.wave.2"
        case "Subtitle": "captions.bubble"
        default: "doc"
        }
    }

    private var rows: [(String, String)] {
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
                ("动态范围", stream.videoRangeType),
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
    }
}
