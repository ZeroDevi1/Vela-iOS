import SwiftUI
import VelaNetwork

struct MusicMetadataSection: View {
    let source: MusicSource
    let id: String
    let isArtist: Bool
    var artistName: String?
    @State private var metadata: NavidromeMetadata?
    @State private var top: [NavidromeTrack] = []
    @State private var requested = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !requested || failure != nil {
                Button(isArtist ? "加载歌手资料与热门歌曲" : "加载专辑资料", systemImage: "info.circle") {
                    Task { await load() }
                }
                .disabled(loading).padding(.horizontal, 16)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if let text = metadata?.biography ?? metadata?.notes, !text.isEmpty {
                Text(text).font(.subheadline).textSelection(.enabled).padding(.horizontal, 16)
            }
            if let url = metadata?.lastFmUrl, let safe = musicWebURL(url.absoluteString) {
                Link("打开外部资料", destination: safe).padding(.horizontal, 16)
            }
            if let artists = metadata?.similarArtist, !artists.isEmpty {
                Text("相似歌手").font(.headline).padding(.horizontal, 16)
                ForEach(artists.filter { !$0.id.isEmpty && $0.id != "-1" }) { artist in
                    MusicDestinationRow(title: artist.name, subtitle: nil, icon: "person", route: .artist(artist.id, artist.name))
                }
            }
            if !top.isEmpty {
                Text("热门歌曲").font(.headline).padding(.horizontal, 16)
                MusicTrackRows(tracks: top, source: source)
            }
        }
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            if isArtist {
                let client = source.client
                let name = artistName ?? ""
                let key = source.capabilities.supports("topSongsByArtistId") ? id : nil
                async let profile = client.artistInfo(id)
                async let songs = try? client.topSongs(artist: name, id: key)
                metadata = try await profile
                top = await songs ?? []
            } else {
                metadata = try await source.client.albumInfo(id)
            }
            requested = true
            if (metadata?.notes ?? metadata?.biography ?? "").isEmpty, metadata?.similarArtist?.isEmpty != false,
               metadata?.lastFmUrl == nil, top.isEmpty {
                failure = "未找到资料，请检查服务器的外部资料来源设置。"
            }
        } catch { failure = error.localizedDescription }
    }
}

struct MusicRelatedTracks: View {
    let source: MusicSource
    let track: NavidromeTrack
    @State private var songs: [NavidromeTrack]?
    @State private var busy = false
    @State private var showPath = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("相似歌曲", systemImage: "sparkles") { load(sonic: false) }
                if source.capabilities.supports("sonicSimilarity") {
                    Menu("声音相似度", systemImage: "waveform") {
                        Button("声音相近的歌曲") { load(sonic: true) }
                        Button("查找两首歌之间的路径") { showPath = true }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .disabled(busy)
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if let songs {
                if songs.isEmpty { Text("暂无相似歌曲").foregroundStyle(.secondary).padding(.horizontal, 16) }
                else { MusicTrackRows(tracks: songs, source: source) }
            }
        }
        .padding(.vertical, 10)
        .sheet(isPresented: $showPath) { MusicSonicPath(source: source, start: track) }
    }

    private func load(sonic: Bool) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { songs = try await (sonic ? source.client.sonicMatches(from: track.id) : source.client.similarSongs(track.id)) }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct MusicSonicPath: View {
    let source: MusicSource
    let start: NavidromeTrack
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [NavidromeTrack] = []
    @State private var result: [NavidromeTrack]?
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("起点") { Text(start.title) }
                if let result {
                    Section("匹配路径") {
                        if result.isEmpty { Text("未找到路径") }
                        else {
                            Button("播放整条路径") { app.playMusic(result, at: 0, from: source); dismiss() }
                            ForEach(result.indices, id: \.self) { Text(result[$0].title) }
                        }
                        Button("重新查找") { self.result = nil }
                    }
                } else {
                    Section("选择终点") {
                        TextField("搜索歌曲", text: $query)
                        ForEach(candidates.filter { $0.id != start.id }) { track in
                            Button(track.title) { loadPath(track) }.disabled(busy)
                        }
                    }
                }
                if busy { ProgressView() }
                if let failure { Text(failure).foregroundStyle(.secondary) }
            }
            .navigationTitle("歌曲之间的路径")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .frame(minWidth: 320, minHeight: 320)
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { candidates = []; return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                candidates = try await source.client.search(term, limit: 20, songsOnly: true).song ?? []
                failure = nil
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private func loadPath(_ destination: NavidromeTrack) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { result = try await source.client.sonicMatches(from: start.id, to: destination.id) }
            catch { failure = error.localizedDescription }
        }
    }
}
