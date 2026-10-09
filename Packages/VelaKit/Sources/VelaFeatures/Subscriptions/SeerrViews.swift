import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// Seerr 连接（当前媒体服务器）：与 Android 版一致，用媒体服务器账号或 Seerr 本地账号（邮箱）登录。
struct SeerrConnectionForm: View {
    @Environment(AppModel.self) private var app
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    private var serverID: String? { app.servers.activeServer?.id }
    private var connection: SeerrService.Connection? { app.seerr.connection(for: serverID) }

    var body: some View {
        Form {
            if let connection, let serverID {
                Section("当前连接") {
                    LabeledContent("地址", value: connection.url)
                    LabeledContent("账号", value: connection.username)
                    if let version = connection.version { LabeledContent("版本", value: version) }
                    NavigationLink("我的请求") { SeerrRequestsView() }
                    Button("断开连接", role: .destructive) { app.seerr.disconnect(serverID: serverID) }
                }
            }
            Section {
                TextField("地址，例如 https://requests.example.com", text: $url)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("媒体服务器用户名或 Seerr 邮箱", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                    .textContentType(.password)
            } header: {
                Text(connection == nil ? "连接 Seerr" : "重新连接")
            } footer: {
                Text("连接只对当前媒体服务器（\(app.servers.activeServer?.displayName ?? "未选择")）生效。密码只用于登录，不会保存；登录会话保存在本机钥匙串。")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Section {
                if isConnecting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Button("连接") { Task { await connect() } }
                        .disabled(url.isEmpty || username.isEmpty || password.isEmpty || serverID == nil)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Seerr")
        .onAppear {
            if url.isEmpty { url = connection?.url ?? "" }
            if username.isEmpty { username = connection?.username ?? "" }
        }
    }

    private func connect() async {
        guard let server = app.servers.activeServer else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await app.seerr.connect(serverID: server.id, url: url, username: username, password: password,
                                        mediaServerURL: server.baseURL.absoluteString)
            password = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 当前用户在 Seerr 上的请求（新的在前），标题与海报经 TMDB 补全（未配置 TMDB 时只显示 id）。
struct SeerrRequestsView: View {
    @Environment(AppModel.self) private var app
    @State private var requests: LoadState<[(SeerrClient.Request, CatalogTitle?)]> = .idle

    var body: some View {
        List {
            switch requests {
            case .loaded(let list) where list.isEmpty:
                Text("还没有请求").foregroundStyle(.secondary)
            case .loaded(let list):
                ForEach(list, id: \.0.id) { request, title in
                    let row = HStack(spacing: 12) {
                        RemoteArtwork(url: CatalogImage.url(title?.posterPath, size: .poster), placeholderSymbol: "film")
                            .frame(width: 44, height: 66)
                            .clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title?.title ?? "TMDB \(request.tmdbID.map(String.init) ?? "-")").font(.subheadline.weight(.semibold))
                            Text("\(request.requestStatusTitle) · \(request.mediaStatus.title)").font(.caption).foregroundStyle(.secondary)
                            if let date = request.createdAt {
                                Text(date, format: .dateTime.year().month().day()).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let title {
                        NavigationLink(value: title) { row }
                    } else {
                        row
                    }
                }
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("我的请求")
        .navigationDestination(for: CatalogTitle.self) { CatalogDetailView(title: $0) }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = try? app.seerr.client(for: app.servers.activeServer?.id) else {
            requests = .failed("未连接 Seerr")
            return
        }
        let tmdb = app.catalog.client
        requests = LoadState(await capture {
            let user = try await client.currentUser()
            let list = try await client.myRequests(userID: user.id)
            return await withTaskGroup(of: (Int, CatalogTitle?).self) { group in
                for (index, request) in list.enumerated() {
                    group.addTask {
                        guard let tmdb, let id = request.tmdbID, let type = request.mediaType else { return (index, nil) }
                        return (index, try? await tmdb.title(type, id: id))
                    }
                }
                var titles = [CatalogTitle?](repeating: nil, count: list.count)
                for await (index, title) in group { titles[index] = title }
                return Array(zip(list, titles))
            }
        })
    }
}

/// 目录详情页的 Seerr 请求：显示条目状态；电影一键请求，剧集选择要请求的季。
struct SeerrRequestControl: View {
    let title: CatalogTitle
    @Environment(AppModel.self) private var app
    @State private var info: SeerrClient.Title?
    @State private var isWorking = false
    @State private var message: String?
    @State private var showsSeasonPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: VelaTheme.Spacing.s) {
                if let info {
                    if info.status == .available || info.status == .blacklisted {
                        Label("Seerr：\(info.status.title)", systemImage: "checkmark.seal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            if title.mediaType == .tv { showsSeasonPicker = true } else { Task { await request(seasons: nil) } }
                        } label: {
                            Label(info.status == .unknown ? "通过 Seerr 请求" : "Seerr：\(info.status.title)",
                                  systemImage: info.status == .unknown ? "paperplane" : "clock")
                        }
                        .buttonStyle(.bordered)
                        // 已请求的电影不能重复请求；剧集仍可补请求其他季。
                        .disabled(isWorking || (title.mediaType == .movie && info.status != .unknown))
                    }
                } else if message == nil {
                    ProgressView().controlSize(.small)
                }
                if isWorking { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task(id: title.id) { await load() }
        .sheet(isPresented: $showsSeasonPicker) {
            if let info {
                SeerrSeasonPicker(info: info) { seasons in
                    Task { await request(seasons: seasons) }
                }
            }
        }
    }

    private func load() async {
        guard let client = try? app.seerr.client(for: app.servers.activeServer?.id) else { return }
        do {
            info = try await client.title(title.mediaType, tmdbID: title.tmdbID)
            message = nil
        } catch {
            message = "Seerr：\(error.localizedDescription)"
        }
    }

    private func request(seasons: [Int]?) async {
        guard let client = try? app.seerr.client(for: app.servers.activeServer?.id) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.request(title.mediaType, tmdbID: title.tmdbID, seasons: seasons)
            message = "已提交请求"
            await load()
        } catch {
            message = "请求失败：\(error.localizedDescription)"
        }
    }
}

private struct SeerrSeasonPicker: View {
    let info: SeerrClient.Title
    let onRequest: ([Int]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int> = []

    /// 已可用或已在处理的季不能再次请求。
    private var requestable: [SeerrClient.Title.Season] {
        info.seasons.filter { $0.status == .unknown }
    }

    var body: some View {
        NavigationStack {
            List(info.seasons) { season in
                let available = season.status == .unknown
                Toggle(isOn: Binding(
                    get: { selection.contains(season.number) },
                    set: { if $0 { selection.insert(season.number) } else { selection.remove(season.number) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(season.name ?? "第 \(season.number) 季")
                        if !available { Text(season.status.title).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .disabled(!available)
            }
            .navigationTitle("选择要请求的季")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("请求") {
                        onRequest(selection.sorted())
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .onAppear { selection = Set(requestable.map(\.number)) }
        }
    }
}
