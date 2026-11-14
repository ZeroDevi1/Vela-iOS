import SwiftUI
import VelaNetwork

struct MusicServerSection: View {
    let source: MusicSource

    var body: some View {
        Section("Navidrome") {
            NavigationLink("账号与服务状态") { MusicServerStatus(source: source) }
            NavigationLink("网络电台") { MusicRadios(source: source) }
            if source.canShare { NavigationLink("分享链接") { MusicShares(source: source) } }
            if source.canUseJukebox { NavigationLink("服务器播放器") { MusicJukebox(source: source) } }
        }
    }
}

private struct MusicServerStatus: View {
    let source: MusicSource
    @State private var scan: NavidromeScan?
    @State private var folders: [NavidromeFolder] = []
    @State private var users: [NavidromeUser] = []
    @State private var license: Bool?
    @State private var avatar: Data?
    @State private var failure: String?
    @State private var busy = false
    @State private var confirmScan = false
    @State private var fullScan = false
    @State private var library: Int?
    @State private var scanPath = ""

    var body: some View {
        Form {
            Section("当前账号") {
                #if os(iOS)
                if let avatar, let image = UIImage(data: avatar) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 50, height: 50).clipShape(Circle())
                }
                #else
                if let avatar, let image = NSImage(data: avatar) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 50, height: 50).clipShape(Circle())
                }
                #endif
                if let user = source.user {
                    LabeledContent("用户名", value: user.username)
                    LabeledContent("权限", value: user.adminRole == true ? "管理员" : "普通账户")
                }
                if let license { LabeledContent("Subsonic 许可", value: license ? "有效" : "无效") }
                if source.isAdmin {
                    ForEach(users.filter { $0.username != source.user?.username }) { user in Text(user.username) }
                }
            }
            Section("可访问的曲库") {
                ForEach(folders) { folder in Text(folder.name) }
                if folders.isEmpty { Text("未返回曲库").foregroundStyle(.secondary) }
            }
            Section("扫描") {
                if let scan {
                    LabeledContent("状态", value: scan.scanning ? "扫描中" : "空闲")
                    LabeledContent("歌曲数", value: String(scan.count))
                    if let last = scan.lastScan { LabeledContent("上次扫描", value: last) }
                    if scan.error?.isEmpty == false { Text("上次扫描遇到错误，请查看服务器日志").foregroundStyle(.secondary) }
                }
                if source.isAdmin {
                    Picker("曲库", selection: $library) {
                        Text("全部").tag(nil as Int?)
                        ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if library != nil { TextField("相对目录（可选）", text: $scanPath) }
                    Toggle("完整扫描", isOn: $fullScan)
                    Button("开始扫描") { confirmScan = true }
                        .disabled(busy || scan?.scanning == true)
                }
            }
            Section("OpenSubsonic 扩展") {
                ForEach(source.capabilities.extensions.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: (source.capabilities.extensions[key] ?? []).sorted().map(String.init).joined(separator: "、"))
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            Button("刷新状态") { Task { await load() } }.disabled(busy)
        }
        .formStyle(.grouped)
        .navigationTitle("账号与服务状态")
        .task { await load() }
        .confirmationDialog("在 Navidrome 开始扫描？", isPresented: $confirmScan, titleVisibility: .visible) {
            Button("开始扫描") {
                let targets = library.map { ["\($0):\(scanPath.trimmingCharacters(in: .whitespacesAndNewlines))"] } ?? []
                let full = fullScan
                Task {
                    busy = true
                    defer { busy = false }
                    do { scan = try await source.client.startScan(full: full, targets: targets) }
                    catch { failure = error.localizedDescription }
                }
            }
        }
    }

    private func load() async {
        busy = true
        failure = nil
        defer { busy = false }
        async let accountList = source.isAdmin ? (try? source.client.users()) : nil
        async let image = try? source.client.avatar()
        async let valid = try? source.client.licenseValid()
        async let libraries = try? source.client.musicFolders()
        do { scan = try await source.client.scanStatus() }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
        let details = await (accountList, image, valid, libraries)
        guard !Task.isCancelled else { return }
        users = details.0 ?? []
        if let data = details.1 { avatar = data }
        license = details.2
        folders = details.3 ?? []
    }
}

private struct MusicRadios: View {
    let source: MusicSource
    @Environment(AppModel.self) private var app
    @State private var rows: [NavidromeRadio] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var edit: Editor?
    @State private var deleting: NavidromeRadio?

    struct Editor: Identifiable {
        var id: String { station?.id ?? "new" }
        var station: NavidromeRadio?
    }

    var body: some View {
        List {
            ForEach(rows) { station in
                HStack {
                    Button {
                        guard let url = musicWebURL(station.streamUrl) else { error = "电台的串流地址无效"; return }
                        app.playMusic([.radio(station)], at: 0, from: source, radio: url)
                    } label: { Label(station.name, systemImage: "radio") }
                    .buttonStyle(.plain)
                    Spacer()
                    if source.isAdmin {
                        Menu("电台操作", systemImage: "ellipsis") {
                            Button("编辑") { edit = Editor(station: station) }
                            Button("删除", role: .destructive) { deleting = station }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            if let error { MusicLoadError(message: error) { Task { await load() } } }
            else if rows.isEmpty {
                if loaded { ContentUnavailableView("暂无电台", systemImage: "radio") }
                else { ProgressView() }
            }
        }
        .navigationTitle("网络电台")
        .toolbar {
            if source.isAdmin {
                Button("添加电台", systemImage: "plus") { edit = Editor() }.labelStyle(.iconOnly)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $edit, onDismiss: { Task { await load() } }) { editor in
            MusicRadioEditor(source: source, station: editor.station)
        }
        .confirmationDialog("删除电台？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("删除「\(deleting.name)」", role: .destructive) {
                    Task {
                        do { try await source.client.deleteRadio(deleting.id); await load() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            let list = try await source.client.radios()
            guard !Task.isCancelled else { return }
            rows = list
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loaded = true
    }
}

private struct MusicRadioEditor: View {
    let source: MusicSource
    let station: NavidromeRadio?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var stream = ""
    @State private var website = ""
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("电台名称", text: $name)
                TextField("串流地址", text: $stream)
                TextField("主页（可选）", text: $website)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle(station == nil ? "添加电台" : "编辑电台")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard source.isAdmin, let url = musicWebURL(stream) else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await source.client.saveRadio(id: station?.id, name: name.trimmingCharacters(in: .whitespaces),
                                                                  stream: url, homepage: musicWebURL(website)); dismiss() }
                            catch { failure = error.localizedDescription }
                        }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || musicWebURL(stream) == nil
                              || (!website.isEmpty && musicWebURL(website) == nil))
                }
            }
            .onAppear {
                name = station?.name ?? ""
                stream = station?.streamUrl ?? ""
                website = station?.homePageUrl ?? ""
            }
        }
        .frame(minWidth: 320, minHeight: 280)
    }
}

struct MusicShares: View {
    let source: MusicSource
    @State private var editing: NavidromeShare?
    @State private var deleting: NavidromeShare?
    @State private var refresh = 0
    @State private var failure: String?

    var body: some View {
        MusicLoadedPage { try await source.client.shares() } content: { rows in
            if rows.isEmpty { ContentUnavailableView("暂无分享链接", systemImage: "link") }
            ForEach(rows) { share in
                HStack {
                    VStack(alignment: .leading) {
                        Text(share.description ?? share.id).font(.headline)
                        Text("访问 \(share.visitCount ?? 0) 次").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: share.url).labelStyle(.iconOnly)
                    if source.isAdmin || share.username == source.user?.username {
                        Menu("链接操作", systemImage: "ellipsis") {
                            Button("编辑") { editing = share }
                            Button("撤销链接", role: .destructive) { deleting = share }
                        }.labelStyle(.iconOnly)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .id(refresh)
        .navigationTitle("分享链接")
        .sheet(item: $editing, onDismiss: { refresh += 1 }) { share in
            MusicShareEditor(source: source, share: share)
        }
        .confirmationDialog("撤销此分享链接？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("撤销链接", role: .destructive) {
                    Task {
                        do { try await source.client.deleteShare(deleting.id); refresh += 1 }
                        catch { failure = error.localizedDescription }
                    }
                }
            }
        }
        .alert("无法修改分享", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }
}

struct MusicShareEditor: View {
    let source: MusicSource
    var ids: [String] = []
    var share: NavidromeShare?
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var expires = true
    @State private var expiry = Date.now.addingTimeInterval(86_400)
    @State private var downloadable = false
    @State private var created: NavidromeShare?
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    ShareLink("分享链接", item: created.url)
                } else {
                    TextField("说明", text: $note)
                    Toggle("设置过期时间", isOn: $expires)
                    if expires { DatePicker("过期时间", selection: $expiry) }
                    if source.canDownload, share == nil { Toggle("允许下载", isOn: $downloadable) }
                    if share == nil { Text("获得链接的人可以访问分享内容。").font(.caption).foregroundStyle(.secondary) }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle(share == nil ? "创建分享" : "编辑分享")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(created == nil ? "取消" : "完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if created == nil {
                        Button(share == nil ? "创建链接" : "保存") { save() }
                            .disabled(saving || (expires && expiry <= .now))
                    }
                }
            }
            .onAppear {
                guard let share else { return }
                note = share.description ?? ""
                let date = share.expires.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
                    ?? share.expires.flatMap { try? Date.ISO8601FormatStyle().parse($0) }
                expires = date.map { $0.timeIntervalSince1970 > 0 } ?? false
                if let date, expires { expiry = date }
            }
        }
        .frame(minWidth: 320, minHeight: 310)
    }

    private func save() {
        let date = expires ? expiry : nil
        saving = true
        Task {
            defer { saving = false }
            do {
                if let share {
                    try await source.client.updateShare(share.id, description: note, expires: date, downloadable: nil)
                    dismiss()
                } else {
                    created = try await source.client.createShare(ids: ids, description: note, expires: date, downloadable: downloadable).first
                    if created == nil { dismiss() }
                }
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct MusicJukebox: View {
    let source: MusicSource
    @Environment(AppModel.self) private var app
    @State private var status: NavidromeJukebox?
    @State private var entries: [NavidromeTrack] = []
    @State private var gain = 0.5
    @State private var error: String?
    @State private var busy = false
    @State private var clear = false

    var body: some View {
        Form {
            Section {
                if let status {
                    LabeledContent("播放状态", value: status.playing ? "播放中" : "已停止")
                    LabeledContent("位置", value: musicTime(Double(status.position ?? 0)))
                }
                Button(status?.playing == true ? "停止服务器播放" : "开始服务器播放") {
                    run(status?.playing == true ? .stop : .start)
                }
                HStack {
                    Slider(value: $gain, in: 0...1) { Text("服务器音量") }
                    Button("设置音量") { run(.gain(gain)) }
                }
                Button("刷新状态") { run(.status) }
            } header: { Text("声音由服务器设备输出") }
            Section("服务器队列") {
                if !entries.isEmpty {
                    Button("随机排列") { run(.shuffle) }
                    Button("清空队列", role: .destructive) { clear = true }
                }
                if app.music.source?.id == source.id, !app.music.isRadio, !app.music.queue.isEmpty {
                    Button("追加本机队列") { run(.add(app.music.queue.map(\.id))) }
                    Button("用本机队列替换") { run(.set(app.music.queue.map(\.id))) }
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { index, track in
                    HStack {
                        Button(track.title) { run(.skip(index: index)) }.buttonStyle(.plain)
                        Spacer()
                        if status?.currentIndex == index { Image(systemName: "waveform") }
                        Button("移除", systemImage: "minus.circle") { run(.remove(index)) }.labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("服务器播放器")
        .disabled(busy)
        .task { await command(.get) }
        .refreshable { await command(.get) }
        .confirmationDialog("清空服务器播放队列？", isPresented: $clear) {
            Button("清空", role: .destructive) { run(.clear) }
        }
    }

    private func run(_ action: NavidromeClient.JukeboxAction) {
        Task { await command(action) }
    }

    private func command(_ action: NavidromeClient.JukeboxAction) async {
        guard !busy, source.canUseJukebox else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let form = source.capabilities.supports("formPost")
            let result = try await source.client.jukebox(action, form: form)
            if case .status = action {
                status = result
            } else {
                let queue: NavidromeJukebox
                if case .get = action { queue = result } else { queue = try await source.client.jukebox(.get) }
                status = queue
                entries = queue.entry ?? []
            }
            gain = min(1, max(0, status?.gain ?? 0.5))
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

func musicWebURL(_ input: String) -> URL? {
    guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
          url.user == nil, url.password == nil else { return nil }
    return url
}
