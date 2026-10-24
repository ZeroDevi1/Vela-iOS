import SwiftUI
import VelaCore
import VelaNetwork

/// 服务器管理面板（管理员账号）：系统信息、活动会话、计划任务、扫描媒体库。
///
/// 写操作（执行任务、扫描媒体库）需确认；非管理员账号显示说明而不是空列表。
struct ServerAdminView: View {
    let serverID: String
    @Environment(AppModel.self) private var app
    @State private var isAdmin: Bool?
    @State private var info: ServerSystemInfo?
    @State private var sessions: LoadState<[ServerSession]> = .idle
    @State private var tasks: LoadState<[ScheduledTask]> = .idle
    @State private var pendingTask: ScheduledTask?
    @State private var confirmScan = false
    @State private var actionMessage: String?

    private var client: MediaServerClient? { app.client(forServerID: serverID) }

    var body: some View {
        Form {
            switch isAdmin {
            case .none:
                ProgressView().frame(maxWidth: .infinity)
            case .some(false):
                ContentUnavailableView("需要管理员账号", systemImage: "lock.shield", description: Text("当前账号不是服务器管理员，无法查看管理信息。"))
            case .some(true):
                content
            }
        }
        .formStyle(.grouped)
        .navigationTitle("服务器管理")
        .refreshableLoad { await load() }
        .task { await load() }
        .confirmationDialog("执行「\(pendingTask?.name ?? "")」？", isPresented: Binding(get: { pendingTask != nil }, set: { if !$0 { pendingTask = nil } }), titleVisibility: .visible) {
            Button("立即执行") {
                guard let task = pendingTask else { return }
                Task { await run(task) }
            }
        }
        .confirmationDialog("扫描全部媒体库？", isPresented: $confirmScan, titleVisibility: .visible) {
            Button("开始扫描") { Task { await scan() } }
        } message: {
            Text("服务器将重新扫描所有媒体库，媒体较多时会占用较多资源。")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let actionMessage {
            Label(actionMessage, systemImage: "info.circle")
        }
        Section("系统") {
            LabeledContent("名称", value: info?.serverName ?? "-")
            LabeledContent("版本", value: info?.version ?? "-")
            LabeledContent("系统", value: info?.operatingSystemDisplayName ?? info?.operatingSystem ?? "-")
            if let address = info?.localAddress { LabeledContent("局域网地址", value: address) }
            if info?.hasPendingRestart == true { Label("有待重启的更新", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange) }
            Button("扫描全部媒体库", systemImage: "arrow.triangle.2.circlepath") { confirmScan = true }
            NavigationLink { ActivityLogView(serverID: serverID) } label: {
                Label("活动日志", systemImage: "list.bullet.rectangle")
            }
        }

        Section("活动会话") {
            switch sessions {
            case .loaded(let list) where list.isEmpty:
                Text("当前没有活动会话").foregroundStyle(.secondary)
            case .loaded(let list):
                ForEach(list) { SessionRow(session: $0) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }

        Section("计划任务") {
            switch tasks {
            case .loaded(let list):
                ForEach(list) { task in
                    Button { pendingTask = task } label: { TaskRow(task: task) }
                        .buttonStyle(.plain)
                        .disabled(task.state == "Running")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
    }

    private func load() async {
        guard let client else { return }
        if isAdmin == nil {
            isAdmin = (try? await client.isAdministrator()) ?? false
        }
        guard isAdmin == true else { return }
        async let infoTask = capture { try await client.systemInfo() }
        async let sessionsTask = capture { try await client.activeSessions() }
        async let tasksTask = capture { try await client.scheduledTasks() }
        if case .success(let value) = await infoTask { info = value }
        sessions = LoadState(await sessionsTask)
        tasks = LoadState(await tasksTask.map { $0.sorted { ($0.category ?? "", $0.name) < ($1.category ?? "", $1.name) } })
    }

    private func run(_ task: ScheduledTask) async {
        guard let client else { return }
        do {
            try await client.runScheduledTask(id: task.id)
            actionMessage = "已开始执行「\(task.name)」"
            await load()
        } catch {
            actionMessage = "执行失败：\(error.localizedDescription)"
        }
    }

    private func scan() async {
        guard let client else { return }
        do {
            try await client.refreshLibraries()
            actionMessage = "已开始扫描媒体库"
            await load()
        } catch {
            actionMessage = "扫描失败：\(error.localizedDescription)"
        }
    }
}

private struct SessionRow: View {
    let session: ServerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.userName ?? "未知用户").font(.headline)
                Spacer()
                Text([session.client, session.deviceName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let playing = session.nowPlaying {
                Label([playing.seriesName, playing.name].compactMap { $0 }.joined(separator: " · "),
                      systemImage: session.playState?.isPaused == true ? "pause.fill" : "play.fill")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(playbackDetail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var playbackDetail: String {
        var parts: [String] = []
        if let method = session.playState?.playMethod {
            parts.append(method == "Transcode" ? "转码" : method == "DirectStream" ? "直接串流" : "直接播放")
        }
        if let transcoding = session.transcoding {
            if transcoding.isVideoDirect == true { parts.append("视频直通") } else if let codec = transcoding.videoCodec { parts.append(codec.uppercased()) }
            if let bitrate = transcoding.bitrate { parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        }
        if let ip = session.remoteEndPoint { parts.append(ip) }
        return parts.joined(separator: " · ")
    }
}

private struct TaskRow: View {
    let task: ScheduledTask

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if task.state == "Running" {
                ProgressView(value: (task.progress ?? 0) / 100).frame(width: 60)
            } else {
                Image(systemName: "play.circle").foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }

    private var detail: String {
        var parts = [task.category].compactMap { $0 }
        if let result = task.lastResult {
            if let status = result.status { parts.append(status == "Completed" ? "上次成功" : "上次：\(status)") }
            if let end = result.endTime { parts.append(end.formatted(.relative(presentation: .named))) }
        }
        return parts.joined(separator: " · ")
    }
}

/// 服务器活动日志（与 Android 版服务器信息页一致）：时间倒序，滚动到底部继续加载。
private struct ActivityLogView: View {
    let serverID: String
    @Environment(AppModel.self) private var app
    @State private var entries: [ActivityLogEntry] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?

    private static let pageSize = 50

    var body: some View {
        List {
            ForEach(entries) { entry in
                ActivityRow(entry: entry)
                    .onAppear { if entry.id == entries.last?.id { Task { await loadMore() } } }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("没有活动记录").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("活动日志")
        .refreshableLoad { await reload() }
        .task { await reload() }
    }

    private var hasMore: Bool { total.map { entries.count < $0 } ?? false }

    private func reload() async {
        entries = []
        total = nil
        await load(startIndex: 0)
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(startIndex: entries.count)
    }

    private func load(startIndex: Int) async {
        guard let client = app.client(forServerID: serverID) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.activityLog(startIndex: startIndex, limit: Self.pageSize)
            let known = Set(entries.map(\.id))
            entries += page.entries.filter { !known.contains($0.id) }
            // 服务器未给总数时按本页是否满页判断还有没有更多。
            total = page.total ?? (page.entries.count == Self.pageSize ? entries.count + 1 : entries.count)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.subheadline)
                if let detail = entry.shortOverview ?? entry.overview, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let date = entry.date {
                    Text(date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.level {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case nil: "info.circle"
        }
    }

    private var color: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        case nil: .secondary
        }
    }
}
