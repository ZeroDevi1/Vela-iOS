import SwiftUI
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
    let synced: Bool
    let hasWordTiming: Bool
    let timedRows: [Row]

    init(_ document: NavidromeLyrics) {
        let offset = document.offset ?? 0
        let lines = document.line ?? []
        let cues = Dictionary(grouping: document.cueLine ?? [], by: \.index)
        let agents = document.agents ?? []
        var result: [Row] = []
        var hasWords = false
        for index in Set(lines.indices).union(cues.keys.filter { $0 >= 0 }).sorted() {
            let line = lines.indices.contains(index) ? lines[index] : nil
            let layers = cues[index] ?? []
            let start = line?.start ?? layers.compactMap(\.start).min() ?? layers.flatMap { $0.cue ?? [] }.map(\.start).min()
            let end = line?.end ?? layers.compactMap(\.end).max()
            let next = lines.indices.contains(index + 1) ? lines[index + 1].start : nil
            let voices = layers.enumerated().map { i, layer in
                let agent = agents.first { $0.id == layer.agentId }
                let fragments = Self.fragments(layer, offset: offset, lineEnd: end ?? next)
                hasWords = hasWords || fragments.contains { $0.start != nil }
                return Voice(id: i, name: agent?.name, isBackground: agent?.role == "background", fragments: fragments)
            }
            let fallback = line?.value ?? ""
            guard !voices.isEmpty || !fallback.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append(Row(id: index, start: start.map { ($0 - offset) / 1000 }, end: end.map { ($0 - offset) / 1000 },
                              voices: voices.isEmpty ? [.init(id: 0, name: nil, isBackground: false, fragments: [.init(text: fallback)])] : voices))
        }
        rows = result
        timedRows = result.filter { $0.start != nil }.sorted {
            ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id)
        }
        synced = document.synced && !timedRows.isEmpty
        hasWordTiming = hasWords
    }

    func current(at time: Double) -> Int? {
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
        return row.end.map { time < $0 ? row.id : nil } ?? row.id
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

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
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
}

struct MusicLyricsView: View {
    let source: MusicSource
    let track: NavidromeTrack
    let session: MusicSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var documents: [NavidromeLyrics] = []
    @State private var selected = 0
    @State private var lyrics: KaraokeLyrics?
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0
    @State private var follows = true

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
        .task(id: retry) {
            loading = true
            error = nil
            do {
                let result = try await source.client.lyrics(for: track, enhanced: source.capabilities.supports("songLyrics", version: 2))
                guard !Task.isCancelled else { return }
                documents = result
                selected = result.firstIndex { ($0.kind ?? "main") == "main" && !($0.cueLine ?? []).isEmpty }
                    ?? result.firstIndex { ($0.kind ?? "main") == "main" && $0.synced }
                    ?? result.firstIndex { ($0.kind ?? "main") == "main" } ?? 0
                lyrics = result.indices.contains(selected) ? KaraokeLyrics(result[selected]) : nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { loading = false }
        }
    }

    private func lyricDisplay(_ lyric: KaraokeLyrics) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(lyric.hasWordTiming ? "逐字歌词" : lyric.synced ? "逐行歌词" : "纯文本歌词")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if documents.count > 1 {
                    Picker("歌词版本", selection: $selected) {
                        ForEach(documents.indices, id: \.self) { i in
                            Text(versionTitle(documents[i], index: i)).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selected) { _, i in
                        lyrics = KaraokeLyrics(documents[i])
                        follows = true
                    }
                }
                if lyric.synced && !follows {
                    Button("跟随播放") { follows = true }.font(.caption)
                }
            }
            .padding(.horizontal, 22)
            ScrollViewReader { reader in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !session.isPlaying || !lyric.hasWordTiming)) { _ in
                    let time = session.lyricPosition
                    let active = lyric.current(at: time)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 19) {
                            ForEach(lyric.rows) { row in
                                Button {
                                    guard let start = row.start, session.canSeek else { return }
                                    session.seek(to: start)
                                    follows = true
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(row.voices) { voice in
                                            if let name = voice.name, row.voices.count > 1 {
                                                Text(name).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if active == row.id {
                                                timedText(voice, at: time)
                                                    .foregroundStyle(voice.isBackground ? Color.accentColor.opacity(0.82) : Color.accentColor)
                                            } else {
                                                Text(voice.text).foregroundStyle(lyric.synced ? Color.secondary : .primary)
                                            }
                                        }
                                    }
                                    .font(.title3.weight(active == row.id ? .bold : .semibold))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(row.start == nil || !session.canSeek)
                                .id(row.id)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 24)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { follows = false }
                    }
                    .onChange(of: active, initial: true) { _, id in
                        if follows, let id { scroll(reader, to: id) }
                    }
                    .onChange(of: follows) { _, enabled in
                        if enabled, let active { scroll(reader, to: active) }
                    }
                }
            }
        }
    }

    private func scroll(_ reader: ScrollViewProxy, to id: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { reader.scrollTo(id, anchor: .center) }
    }

    private func timedText(_ voice: KaraokeLyrics.Voice, at time: Double) -> some View {
        let combined = voice.fragments.reduce(Text(verbatim: "")) { text, part in
            let value = Text(verbatim: part.text)
            if let start = part.start, let end = part.end {
                return Text("\(text)\(value.customAttribute(KaraokeCue(start: start, end: end)))")
            }
            return Text("\(text)\(value)")
        }
        return combined.textRenderer(KaraokeFill(time: time))
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
