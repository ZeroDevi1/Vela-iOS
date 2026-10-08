import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// 「订阅」标签页；内容见 `SubscriptionsPage`。
struct SubscriptionsView: View {
    var body: some View {
        NavigationStack { SubscriptionsPage() }
    }
}

/// 订阅：日历（MoviePilot 订阅的播出 / 上映，或 Bangumi 公开放送）+ 我的订阅（MoviePilot）。
struct SubscriptionsPage: View {
    enum Mode: Hashable { case calendar, mine }

    @Environment(AppModel.self) private var app
    @State private var mode: Mode = .calendar
    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 0) {
            if app.subscriptions.isConnected {
                Picker("视图", selection: $mode) {
                    Text("日历").tag(Mode.calendar)
                    Text("我的订阅").tag(Mode.mine)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, VelaTheme.Spacing.l)
                .padding(.vertical, VelaTheme.Spacing.s)
            }
            switch app.subscriptions.isConnected ? mode : .calendar {
            case .calendar: CalendarListView()
            case .mine: MySubscriptionsView()
            }
        }
        .navigationTitle("订阅")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(app.subscriptions.isConnected ? "MoviePilot" : "连接 MoviePilot", systemImage: "link") { isConnecting = true }
            }
        }
        .navigationDestination(for: CatalogTitle.self) { CatalogDetailView(title: $0) }
        .detailDestinations()
        .sheet(isPresented: $isConnecting) {
            NavigationStack { MoviePilotConnectionForm() }
        }
    }
}

// MARK: - 日历

private struct CalendarListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var feed: LoadState<CalendarFeed> = .idle

    var body: some View {
        Group {
            switch feed {
            case .loaded(let feed):
                List {
                    if let warning = feed.warning {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if feed.entries.isEmpty {
                        ContentUnavailableView("近期没有播出", systemImage: "calendar")
                    }
                    ForEach(groups(feed.entries), id: \.date) { group in
                        Section(sectionTitle(group.date)) {
                            ForEach(group.entries) { entry in row(entry) }
                        }
                    }
                    Section {
                    } footer: {
                        Text(feed.source == "Bangumi"
                             ? "数据来自 Bangumi 公开放送表（本周每日放送，不含集数）。连接 MoviePilot 后显示你的订阅。"
                             : "数据来自 MoviePilot 订阅，显示过去 \(CalendarRules.pastDays) 天至未来 \(CalendarRules.futureDays) 天。")
                    }
                }
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .refreshable { await load() }
        .task(id: app.subscriptions.isConnected) { await load() }
    }

    @ViewBuilder
    private func row(_ entry: CalendarEntry) -> some View {
        let content = CalendarRow(entry: entry)
        if let catalog = entry.catalog {
            NavigationLink(value: catalog) { content }
        } else if let url = entry.sourceURL {
            Button { openURL(url) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func load() async {
        if feed.value == nil { feed = .loading }
        feed = LoadState(await app.subscriptions.calendar())
    }

    private func groups(_ entries: [CalendarEntry]) -> [(date: Date, entries: [CalendarEntry])] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, entries: $0.value) }
    }

    private func sectionTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let weekday = date.formatted(.dateTime.weekday(.wide))
        if calendar.isDateInToday(date) { return "今天 · \(weekday)" }
        if calendar.isDateInTomorrow(date) { return "明天 · \(weekday)" }
        if calendar.isDateInYesterday(date) { return "昨天 · \(weekday)" }
        return date.formatted(.dateTime.month().day().weekday(.wide))
    }
}

private struct CalendarRow: View {
    let entry: CalendarEntry

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            RemoteArtwork(url: entry.posterURL, placeholderSymbol: "tv")
                .frame(width: 48, height: 72)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.headline).lineLimit(2)
                if let label = entry.episodeLabel {
                    Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                } else if let original = entry.originalTitle, original != entry.title {
                    Text(original).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

// MARK: - 我的订阅

private struct MySubscriptionsView: View {
    @Environment(AppModel.self) private var app
    @State private var records: LoadState<[SubscriptionRecord]> = .idle
    @State private var pendingRemoval: SubscriptionRecord?
    @State private var actionError: String?

    var body: some View {
        Group {
            switch records {
            case .loaded(let records):
                List {
                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if records.isEmpty {
                        ContentUnavailableView("还没有订阅", systemImage: "bookmark", description: Text("在发现页的作品详情中点「订阅」添加。"))
                    }
                    ForEach(records) { record in
                        Group {
                            if let catalog = record.catalogTitle {
                                NavigationLink(value: catalog) { SubscriptionRow(record: record) }
                            } else {
                                SubscriptionRow(record: record)
                            }
                        }
                        .swipeActions {
                            if app.subscriptions.allowsRemoval {
                                Button("取消订阅", systemImage: "trash", role: .destructive) { pendingRemoval = record }
                            }
                        }
                    }
                }
            case .failed(let message):
                LoadFailureView(message: message) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            "取消订阅「\(pendingRemoval?.name ?? "")」？",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("取消订阅", role: .destructive) {
                guard let record = pendingRemoval else { return }
                Task { await remove(record) }
            }
        } message: {
            Text("将同时删除 MoviePilot 上的这条订阅。")
        }
    }

    private func load() async {
        if records.value == nil { records = .loading }
        records = LoadState(await capture { try await app.subscriptions.subscriptions() })
    }

    private func remove(_ record: SubscriptionRecord) async {
        do {
            try await app.subscriptions.remove(record)
            actionError = nil
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct SubscriptionRow: View {
    let record: SubscriptionRecord

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            RemoteArtwork(url: record.posterURL, placeholderSymbol: "bookmark")
                .frame(width: 48, height: 72)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.headline).lineLimit(2)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !record.stateText.isEmpty {
                Text(record.stateText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = [record.mediaType == .movie ? "电影" : "剧集"]
        if let season = record.season { parts.append("第 \(season) 季") }
        if let year = record.year { parts.append(year) }
        if let total = record.totalEpisodes {
            let lack = record.lackEpisodes ?? 0
            parts.append(lack > 0 ? "缺 \(lack) / \(total) 集" : "共 \(total) 集")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 连接

/// MoviePilot 连接：地址、账号、密码、可选两步验证码。密码只用于换取 token，不保存。
struct MoviePilotConnectionForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        @Bindable var service = app.subscriptions
        Form {
            if app.subscriptions.isConnected {
                Section("当前连接") {
                    LabeledContent("地址", value: app.subscriptions.url)
                    LabeledContent("账号", value: app.subscriptions.username)
                    Toggle("允许在 App 中取消订阅", isOn: $service.allowsRemoval)
                    Button("断开连接", role: .destructive) { app.subscriptions.disconnect() }
                }
            }
            Section {
                TextField("地址，例如 https://mp.example.com", text: $url)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("用户名", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                    .textContentType(.password)
                TextField("两步验证码（未开启可留空）", text: $otp)
                    .textContentType(.oneTimeCode)
            } header: {
                Text(app.subscriptions.isConnected ? "重新连接" : "连接 MoviePilot")
            } footer: {
                Text("密码只用于换取访问令牌，不会保存；令牌保存在本机钥匙串。")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("MoviePilot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isConnecting {
                    ProgressView()
                } else {
                    Button("连接") { Task { await connect() } }
                        .disabled(url.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
        }
        .onAppear {
            if url.isEmpty { url = app.subscriptions.url }
            if username.isEmpty { username = app.subscriptions.username }
        }
    }

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await app.subscriptions.connect(url: url, username: username, password: password, otp: otp)
            password = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
