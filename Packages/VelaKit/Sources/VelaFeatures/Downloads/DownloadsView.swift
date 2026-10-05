import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem

/// 下载列表：进度、失败原因、离线播放与删除。离线播放不上报进度（可能没有网络）。
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var pendingDelete: DownloadRecord?

    var body: some View {
        List {
            if app.downloads.records.isEmpty {
                ContentUnavailableView("没有下载", systemImage: "arrow.down.circle", description: Text("在电影或单集详情页点「下载」，选择画质后开始下载。"))
            }
            ForEach(app.downloads.records) { record in
                Button { play(record) } label: { DownloadRow(record: record) }
                    .buttonStyle(.plain)
                    .disabled(app.downloads.localURL(for: record) == nil)
                    .swipeActions {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = record }
                    }
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = record }
                    }
            }
        }
        .navigationTitle("下载")
        .confirmationDialog(
            "删除「\(pendingDelete?.title ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let record = pendingDelete { app.downloads.delete(record) }
            }
        } message: {
            Text("将删除本机上的下载文件，正在进行的下载会被取消。")
        }
    }

    private func play(_ record: DownloadRecord) {
        guard let url = app.downloads.localURL(for: record) else { return }
        let title = [record.title, record.subtitle].compactMap { $0 }.joined(separator: " · ")
        playMedia(PlaybackRequest(target: .url(url), title: title))
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: VelaTheme.Spacing.m) {
            RemoteArtwork(url: record.posterURL, placeholderSymbol: "film")
                .frame(width: 54, height: 80)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.headline).lineLimit(1)
                if let subtitle = record.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                status
            }
            Spacer(minLength: 0)
            if record.state == .completed {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var status: some View {
        switch record.state {
        case .queued, .downloading:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: record.progress)
                Text("\(record.quality.title) · \(Int(record.progress * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .completed:
            Text([record.quality.title, record.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label(record.errorMessage ?? "下载失败", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

/// 详情页的下载按钮：选择画质后解析下载流并加入队列；已下载 / 下载中显示状态。
struct DownloadButton: View {
    let item: MediaItem
    @Environment(AppModel.self) private var app
    @State private var isResolving = false
    @State private var error: String?

    var body: some View {
        let records = app.downloads.record(serverID: item.serverID, itemID: item.id)
        Menu {
            ForEach(DownloadQuality.allCases, id: \.self) { quality in
                let existing = records.first { $0.quality == quality }
                Button {
                    Task { await start(quality) }
                } label: {
                    Text(quality.title)
                    if let existing { Text(statusText(existing)) }
                }
                .disabled(existing != nil && existing?.state != .failed)
            }
            if let error {
                Text(error)
            }
        } label: {
            Group {
                if isResolving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol(records))
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 30, height: 30)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("下载")
    }

    private func symbol(_ records: [DownloadRecord]) -> String {
        if records.contains(where: { $0.state == .completed }) { return "arrow.down.circle.fill" }
        if records.contains(where: { $0.state == .downloading || $0.state == .queued }) { return "arrow.down.circle.dotted" }
        return "arrow.down.circle"
    }

    private func statusText(_ record: DownloadRecord) -> String {
        switch record.state {
        case .completed: "已下载"
        case .failed: "失败，点按重试"
        case .queued, .downloading: "下载中 \(Int(record.progress * 100))%"
        }
    }

    private func start(_ quality: DownloadQuality) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            let source = try await app.playbackResolver.resolveDownload(item: item, client: client, quality: quality, capabilities: app.capabilities)
            app.downloads.enqueue(item: item, source: source, quality: quality,
                                  posterURL: app.imageURL(for: item, kind: .primary, maxWidth: 300))
            error = nil
        } catch {
            self.error = "无法开始下载：\(error.localizedDescription)"
        }
    }
}
