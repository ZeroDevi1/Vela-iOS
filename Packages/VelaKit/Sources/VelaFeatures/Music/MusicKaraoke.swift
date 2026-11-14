import SwiftUI
import VelaDesignSystem
import VelaNetwork

struct KaraokeLyrics {
    struct Fragment {
        let text: String
        var start: Double? = nil
        var end: Double? = nil
    }

    struct Voice: Identifiable {
        let id: Int
        let name: String?
        let isBackground: Bool
        let fragments: [Fragment]
        var text: String { fragments.map(\.text).joined() }
    }

    struct Row: Identifiable {
        let id: Int
        let start: Double?
        let end: Double?
        let voices: [Voice]
    }

    let rows: [Row]
    let credits: [String]
    let synced: Bool
    private let timedRows: [Row]

    init(_ document: NavidromeLyrics, trackTitle: String) {
        let offset = document.offset ?? 0
        let lines = document.line ?? []
        let cues = Dictionary(grouping: document.cueLine ?? [], by: \.index)
        let agents = document.agents ?? []
        var result: [Row] = []
        for index in Set(lines.indices).union(cues.keys.filter { $0 >= 0 }).sorted() {
            let line = lines.indices.contains(index) ? lines[index] : nil
            let layers = cues[index] ?? []
            let start = line?.start ?? layers.compactMap(\.start).min() ?? layers.flatMap { $0.cue ?? [] }.map(\.start).min()
            let end = line?.end ?? layers.compactMap(\.end).max()
            let next = lines.indices.contains(index + 1) ? lines[index + 1].start : nil
            let voices = layers.enumerated().map { i, layer in
                let agent = agents.first { $0.id == layer.agentId }
                let fragments = Self.fragments(layer, offset: offset, lineEnd: end ?? next)
                return Voice(id: i, name: agent?.name, isBackground: agent?.role == "background", fragments: fragments)
            }
            let fallback = line?.value ?? ""
            let hasText = !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let textVoices = hasText ? [Voice(id: 0, name: nil, isBackground: false, fragments: [.init(text: fallback)])] : []
            result.append(Row(id: index, start: start.map { ($0 - offset) / 1000 }, end: end.map { ($0 - offset) / 1000 },
                              voices: voices.isEmpty ? textVoices : voices))
        }
        let openingCredits = document.synced && cues.isEmpty ? Self.openingCredits(in: result, trackTitle: trackTitle) : []
        credits = openingCredits.compactMap { $0.voices.first?.text }
        let remaining = result.dropFirst(openingCredits.count)
        rows = remaining.filter { !$0.voices.isEmpty }
        timedRows = remaining.filter { $0.start != nil }.sorted {
            ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id)
        }
        synced = document.synced && timedRows.contains { !$0.voices.isEmpty }
    }

    private static func openingCredits(in rows: [Row], trackTitle: String) -> [Row] {
        let labels: Set<String> = ["词", "作词", "曲", "作曲", "编曲", "制作人", "联合制作人", "配唱监制", "吉他", "贝斯",
                                   "和声编写", "和声", "人声录音", "音频编辑", "混音", "母带", "混音/母带", "全景声混音",
                                   "a&r", "制作统筹", "企划协力", "出品人", "出品", "lyrics", "composer", "producer"]
        let first = rows.first?.voices.first?.text ?? ""
        let title = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let skipTitle = !title.isEmpty && first.localizedCaseInsensitiveContains(title) ? 1 : 0
        let matched = rows.dropFirst(skipTitle).prefix { row in
            guard let text = row.voices.first?.text, let separator = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
            let label = text[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            return labels.contains(label)
        }
        guard matched.count >= 2, rows.dropFirst(skipTitle + matched.count).contains(where: { !$0.voices.isEmpty }) else { return [] }
        return Array(rows.prefix(skipTitle + matched.count))
    }

    func current(at time: Double) -> (id: Int, start: Double, end: Double?)? {
        guard synced else { return nil }
        var low = 0
        var high = timedRows.count
        while low < high {
            let mid = (low + high) / 2
            if (timedRows[mid].start ?? 0) <= time { low = mid + 1 }
            else { high = mid }
        }
        guard low > 0 else { return nil }
        let row = timedRows[low - 1]
        guard !row.voices.isEmpty, let start = row.start, row.end.map({ time < $0 }) != false else { return nil }
        let nextStart = low < timedRows.count ? timedRows[low].start : nil
        return (row.id, start, row.end ?? nextStart)
    }

    private static func fragments(_ layer: NavidromeLyrics.CueLine, offset: Double, lineEnd: Double?) -> [Fragment] {
        let bytes = Array(layer.value.utf8)
        let cues = layer.cue ?? []
        var result: [Fragment] = []
        var cursor = 0
        for (index, cue) in cues.enumerated() {
            guard let start = cue.byteStart, let end = cue.byteEnd, start >= cursor, end >= start, end < bytes.count,
                  let text = String(bytes: bytes[start...end], encoding: .utf8),
                  let gap = String(bytes: bytes[cursor..<start], encoding: .utf8) else { continue }
            if !gap.isEmpty { result.append(.init(text: gap)) }
            let next = cues.indices.contains(index + 1) ? cues[index + 1].start : nil
            let finish = cue.end ?? next ?? layer.end ?? lineEnd ?? cue.start + 350
            result.append(.init(text: text, start: (cue.start - offset) / 1000, end: (max(cue.start + 1, finish) - offset) / 1000))
            cursor = end + 1
        }
        if cursor < bytes.count { result.append(.init(text: String(decoding: bytes[cursor...], as: UTF8.self))) }
        return result.isEmpty ? [.init(text: layer.value)] : result
    }
}

private struct KaraokeCue: TextAttribute {
    var start: Double
    var end: Double
}

private struct KaraokeFill: TextRenderer {
    let time: Double
    var lineProgress: Double? = nil

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if let lineProgress {
            drawLineProgress(layout, progress: lineProgress, in: context)
            return
        }
        for line in layout {
            for run in line {
                guard let cue = run[KaraokeCue.self] else { context.draw(run); continue }
                let fraction = min(1, max(0, (time - cue.start) / (cue.end - cue.start)))
                var dim = context
                dim.opacity *= 0.43
                dim.draw(run)
                guard fraction > 0 else { continue }
                var bright = context
                var rect = run.typographicBounds.rect
                rect.size.width *= fraction
                bright.clip(to: Path(rect.insetBy(dx: 0, dy: -4)))
                bright.draw(run)
            }
        }
    }

    private func drawLineProgress(_ layout: Text.Layout, progress: Double, in context: GraphicsContext) {
        var remaining = layout.reduce(CGFloat.zero) { $0 + $1.typographicBounds.rect.width } * progress
        var dim = context
        dim.opacity *= 0.43
        for line in layout {
            var rect = line.typographicBounds.rect
            if remaining >= rect.width {
                context.draw(line)
                remaining -= rect.width
            } else {
                dim.draw(line)
                if remaining > 0 {
                    var bright = context
                    rect.size.width = remaining
                    bright.clip(to: Path(rect.insetBy(dx: 0, dy: -4)))
                    bright.draw(line)
                    remaining = 0
                }
            }
        }
    }
}

struct MusicLyricsView: View {
    let source: MusicSource
    let track: NavidromeTrack
    let session: MusicSession
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var documents: [NavidromeLyrics] = []
    @State private var selected = 0
    @State private var lyrics: KaraokeLyrics?
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0
    @State private var isBrowsing = false

    var body: some View {
        Group {
            if loading {
                ProgressView("正在获取歌词").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                MusicLoadError(message: error) { retry += 1 }
            } else if let lyrics, !lyrics.rows.isEmpty {
                lyricDisplay(lyrics)
            } else {
                ContentUnavailableView("暂无歌词", systemImage: "quote.bubble",
                                       description: Text("这首歌曲没有可显示的歌词。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isActive ? retry : nil) {
            guard isActive, loading || error != nil else { return }
            loading = true
            error = nil
            do {
                let result = try await source.client.lyrics(for: track, enhanced: source.capabilities.supports("songLyrics", version: 2))
                guard !Task.isCancelled else { return }
                documents = result
                selected = result.firstIndex { ($0.kind ?? "main") == "main" && $0.synced && !($0.cueLine ?? []).isEmpty }
                    ?? result.firstIndex { ($0.kind ?? "main") == "main" && $0.synced }
                    ?? result.firstIndex { ($0.kind ?? "main") == "main" } ?? 0
                lyrics = result.indices.contains(selected) ? KaraokeLyrics(result[selected], trackTitle: track.title) : nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { loading = false }
        }
    }

    private func lyricDisplay(_ lyric: KaraokeLyrics) -> some View {
        VStack(spacing: 0) {
            if documents.count > 1 {
                Picker("歌词版本", selection: $selected) {
                    ForEach(documents.indices, id: \.self) { i in
                        Text(versionTitle(documents[i], index: i)).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 22)
                .onChange(of: selected) { _, i in
                    isBrowsing = false
                    lyrics = KaraokeLyrics(documents[i], trackTitle: track.title)
                }
            }
            ScrollViewReader { reader in
                let playing = session.isPlaying
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || !playing || !lyric.synced)) { _ in
                    let time = session.lyricPosition
                    let cue = lyric.current(at: time)
                    let active = cue?.id
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 21) {
                            ForEach(lyric.rows) { row in
                                Button {
                                    guard let start = row.start, session.canSeek else { return }
                                    session.seek(to: start)
                                    if active == row.id { scroll(reader, to: row.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(row.voices) { voice in
                                            if let name = voice.name, row.voices.count > 1 {
                                                Text(name).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if let cue, cue.id == row.id {
                                                timedText(voice, at: time, start: cue.start, end: cue.end)
                                                    .foregroundStyle(VelaTheme.accent.opacity(voice.isBackground ? 0.82 : 1))
                                            } else {
                                                Text(voice.text).foregroundStyle(lyric.synced ? Color.secondary : .primary)
                                            }
                                        }
                                    }
                                    .font(.title2.weight(active == row.id ? .bold : .regular))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(row.start == nil || !session.canSeek)
                                .id(row.id)
                            }
                            if !lyric.credits.isEmpty {
                                DisclosureGroup("制作信息") {
                                    Text(lyric.credits.joined(separator: "\n"))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 6)
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 24)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting {
                            isBrowsing = true
                        } else if phase == .idle, isBrowsing {
                            isBrowsing = false
                            if isActive, playing, let active { scroll(reader, to: active) }
                        }
                    }
                    .onChange(of: active, initial: true) { _, id in
                        if isActive, !isBrowsing, let id { scroll(reader, to: id) }
                    }
                    .onChange(of: playing) { _, playing in
                        if isActive, playing, !isBrowsing, let active { scroll(reader, to: active) }
                    }
                    .onChange(of: isActive) { _, visible in
                        isBrowsing = false
                        if visible, let active { scroll(reader, to: active) }
                    }
                }
            }
            .id(selected)
        }
    }

    private func scroll(_ reader: ScrollViewProxy, to id: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { reader.scrollTo(id, anchor: .center) }
    }

    private func timedText(_ voice: KaraokeLyrics.Voice, at time: Double, start: Double, end: Double?) -> some View {
        let lineProgress: Double? = if let end, end > start, !voice.fragments.contains(where: { $0.start != nil }) {
            min(1, max(0, (time - start) / (end - start)))
        } else {
            nil
        }
        let combined = voice.fragments.reduce(Text(verbatim: "")) { text, part in
            let value = Text(verbatim: part.text)
            if let start = part.start, let end = part.end {
                return Text("\(text)\(value.customAttribute(KaraokeCue(start: start, end: end)))")
            }
            return Text("\(text)\(value)")
        }
        return combined.textRenderer(KaraokeFill(time: time, lineProgress: lineProgress))
    }

    private func versionTitle(_ lyric: NavidromeLyrics, index: Int) -> String {
        let language = lyric.lang.flatMap { Locale.current.localizedString(forLanguageCode: $0) ?? $0 } ?? "版本 \(index + 1)"
        switch lyric.kind {
        case "translation": return "翻译 · " + language
        case "pronunciation": return "注音 · " + language
        default: return language + (lyric.cueLine?.isEmpty == false ? " · 逐字" : "")
        }
    }
}
