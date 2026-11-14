import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import VelaNetwork

struct MusicItemActions: View {
    let source: MusicSource
    let id: String
    let title: String
    let kind: NavidromeClient.FavoriteKind
    let starred: Bool
    var rating: Int? = nil
    var track: NavidromeTrack? = nil

    @Environment(AppModel.self) private var app
    @State private var localStar: Bool?
    @State private var localRating: Int?
    @State private var busy = false
    @State private var share = false
    @State private var pickPlaylist = false
    @State private var error: String?

    var body: some View {
        HStack {
            Button(localStar ?? starred ? "取消收藏" : "收藏", systemImage: localStar ?? starred ? "heart.fill" : "heart") {
                let next = !(localStar ?? starred)
                run {
                    try await source.client.setFavorite(next, id: id, kind: kind)
                    localStar = next
                }
            }
            if kind == .song {
                Menu("\(localRating ?? rating ?? 0) 分", systemImage: "star") {
                    ForEach(0...5, id: \.self) { value in
                        Button(value == 0 ? "清除评分" : "\(value) 星") {
                            run { try await source.client.setRating(value, id: id); localRating = value }
                        }
                    }
                }
            }
            if track != nil || (source.canShare && kind != .artist) {
                Menu("更多操作", systemImage: "ellipsis.circle") {
                    if let track {
                        Button("添加到歌单", systemImage: "music.note.list") { pickPlaylist = true }
                        Button("保存播放书签", systemImage: "bookmark") {
                            let time = app.music.source?.id == source.id && app.music.current?.id == track.id ? app.music.position : 0
                            run { try await source.client.saveBookmark(track.id, position: time) }
                        }
                    }
                    if source.canShare, kind != .artist {
                        Button("创建分享链接", systemImage: "link") { share = true }
                    }
                }
                .labelStyle(.iconOnly)
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .sheet(isPresented: $share) { MusicShareEditor(source: source, ids: [id]) }
        .sheet(isPresented: $pickPlaylist) {
            if let track { MusicPlaylistPicker(source: source, tracks: [track]) }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
        if source.canDownload && !source.isPrivate {
            MusicDownloadButton(source: source, id: id, title: title, album: kind != .song)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}

struct MusicDownloadButton: View {
    private struct OriginalFile: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
        }
    }

    let source: MusicSource
    let id: String
    let title: String
    var album = false
    @State private var working = false
    @State private var exported: URL?
    @State private var stagedFolder: URL?
    @State private var error: String?
    @State private var downloading: Task<Void, Never>?
    @State private var savesFile = false

    var body: some View {
        HStack {
            if let exported {
                Button("存储到文件", systemImage: "folder") { savesFile = true }
                ShareLink("分享文件", item: exported)
            } else if working {
                ProgressView().controlSize(.small)
                Button("取消下载") { downloading?.cancel() }
            } else {
                Button("下载原始文件", systemImage: "arrow.down.circle") { download() }
            }
        }
        .fileExporter(isPresented: $savesFile, item: exported.map { OriginalFile(url: $0) }, contentTypes: [.data],
                      defaultFilename: exported?.lastPathComponent) { outcome in
            if case .failure(let error) = outcome { self.error = error.localizedDescription }
        }
        .onDisappear {
            downloading?.cancel()
            if let stagedFolder { try? FileManager.default.removeItem(at: stagedFolder) }
        }
        .alert("下载失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func download() {
        working = true
        downloading = Task {
            defer { working = false }
            do {
                let (file, filename) = try await source.client.download(id: id)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                stagedFolder = directory
                let defaultName = title + (album ? ".zip" : "")
                let name = (filename ?? defaultName).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
                let safeName = name.isEmpty || name == "." || name == ".." ? "Navidrome 下载" : name
                let target = directory.appending(path: safeName)
                try FileManager.default.moveItem(at: file, to: target)
                exported = target
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MusicPlaylistEditor: View {
    let source: MusicSource
    var playlist: MusicPlaylist?
    var tracks: [NavidromeTrack] = []
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var visibility = false
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("歌单名称", text: $name)
                if playlist != nil {
                    TextField("说明", text: $comment)
                    Toggle("公开歌单", isOn: $visibility)
                }
                if !tracks.isEmpty { Text("\(tracks.count) 首歌曲").foregroundStyle(.secondary) }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle(playlist == nil ? "新建歌单" : "编辑歌单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = playlist?.name ?? ""
                comment = playlist?.comment ?? ""
                visibility = playlist?.public == true
            }
        }
        .frame(minWidth: 320, minHeight: 270)
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let name = name.trimmingCharacters(in: .whitespaces)
                let form = source.capabilities.supports("formPost")
                if let playlist {
                    try await source.client.updatePlaylist(playlist.id, name: name, comment: comment, isPublic: visibility, form: form)
                } else {
                    _ = try await source.client.createPlaylist(name: name, songIDs: tracks.map(\.id), form: form)
                }
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct MusicPlaylistPicker: View {
    let source: MusicSource
    let tracks: [NavidromeTrack]
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            MusicLoadedPage { try await source.client.playlists().filter { editable($0, source: source) } } content: { lists in
                if lists.isEmpty { ContentUnavailableView("没有可编辑的歌单", systemImage: "music.note.list") }
                ForEach(lists) { playlist in
                    Button {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await source.client.updatePlaylist(playlist.id, adding: tracks.map(\.id), form: source.capabilities.supports("formPost"))
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list").frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .disabled(busy)
            .navigationTitle("添加到歌单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { creating = true } }
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .sheet(isPresented: $creating) { MusicPlaylistEditor(source: source, tracks: tracks) }
        .alert("添加失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

private func editable(_ playlist: MusicPlaylist, source: MusicSource) -> Bool {
    playlist.readonly != true && (source.isAdmin || (playlist.owner != nil && playlist.owner == source.user?.username))
}

struct MusicEditablePlaylist: View {
    let source: MusicSource
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MusicPlaylist?
    @State private var sharing = false
    @State private var deleting: MusicPlaylist?
    @State private var removing: Int?
    @State private var refresh = 0
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        MusicLoadedPage { try await source.client.playlist(id) } content: { playlist in
            let tracks = playlist.entry ?? []
            VStack(spacing: 9) {
                MusicCover(source: source, id: playlist.coverArt, glyph: "music.note.list", radius: 14).frame(width: 148)
                Text(playlist.name).font(.title2.bold())
                Text("\(tracks.count) 首歌曲").foregroundStyle(.secondary)
                if let comment = playlist.comment, !comment.isEmpty { Text(comment).font(.subheadline) }
                HStack {
                    Button("播放全部", systemImage: "play.fill") { app.playMusic(tracks, at: 0, from: source) }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty)
                    if editable(playlist, source: source) {
                        Menu("编辑") {
                            Button("编辑歌单") { editing = playlist }
                            Button("删除歌单", role: .destructive) { deleting = playlist }
                        }
                    }
                    if source.canShare, !tracks.isEmpty {
                        Button("分享", systemImage: "link") { sharing = true }
                    }
                }
            }
            .frame(maxWidth: .infinity).padding(12)
            if editable(playlist, source: source) {
                ForEach(tracks.indices, id: \.self) { index in
                    HStack {
                        Button {
                            app.playMusic(tracks, at: index, from: source)
                        } label: {
                            MusicTrackLabel(track: tracks[index], source: source)
                        }.buttonStyle(.plain)
                        Button("从歌单移除", systemImage: "minus.circle") { removing = index }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                    }.padding(.horizontal, 16)
                }
            } else {
                MusicTrackRows(tracks: tracks, source: source)
            }
            if source.canDownload && !source.isPrivate {
                MusicDownloadButton(source: source, id: id, title: playlist.name, album: true).padding(16)
            }
        }
        .id(refresh)
        .disabled(busy)
        .sheet(item: $editing, onDismiss: { refresh += 1 }) { MusicPlaylistEditor(source: source, playlist: $0) }
        .sheet(isPresented: $sharing) { MusicShareEditor(source: source, ids: [id]) }
        .confirmationDialog("删除服务器上的歌单？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除歌单", role: .destructive) { mutate { try await source.client.deletePlaylist(id); dismiss() } }
        }
        .confirmationDialog("从歌单移除此曲目？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing {
                Button("移除", role: .destructive) {
                    mutate {
                        try await source.client.updatePlaylist(id, removing: [removing], form: source.capabilities.supports("formPost"))
                        refresh += 1
                    }
                }
            }
        }
        .alert("无法编辑歌单", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func mutate(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}

struct MusicBookmarksPage: View {
    let source: MusicSource
    @Environment(AppModel.self) private var app
    @State private var removing: NavidromeBookmark?
    @State private var refresh = 0
    @State private var error: String?

    var body: some View {
        MusicLoadedPage { try await source.client.bookmarks() } content: { items in
            if items.isEmpty { ContentUnavailableView("暂无书签", systemImage: "bookmark") }
            ForEach(items) { bookmark in
                HStack {
                    Button {
                        app.playMusic([bookmark.entry], at: 0, from: source, position: Double(bookmark.position) / 1000)
                    } label: {
                        HStack {
                            MusicTrackLabel(track: bookmark.entry, source: source)
                            Text(musicTime(Double(bookmark.position) / 1000)).font(.caption.monospacedDigit())
                        }
                    }.buttonStyle(.plain)
                    Button("删除书签", systemImage: "trash") { removing = bookmark }.labelStyle(.iconOnly).buttonStyle(.plain)
                }.padding(.horizontal, 16)
            }
        }
        .id(refresh)
        .confirmationDialog("删除服务器书签？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing {
                Button("删除", role: .destructive) {
                    Task {
                        do { try await source.client.deleteBookmark(removing.id); refresh += 1 }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        .alert("无法删除书签", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
