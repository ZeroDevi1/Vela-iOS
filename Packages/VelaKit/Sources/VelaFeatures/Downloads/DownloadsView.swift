import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// 下载列表：进度、失败原因、离线播放与删除。离线播放不上报进度（可能没有网络）。
struct DownloadsView: View {
    /// 无网络时作为首页显示：顶部说明离线状态，只列出可播放的已完成下载。
    var isOffline = false
    @Environment(AppModel.self) private var app
    @Environment(\.playMedia) private var playMedia
    @State private var pendingDelete: DownloadRecord?

    var body: some View {
        List {
            if isOffline {
                Section {
                    Label("当前没有网络连接，可以播放已下载的内容", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            if app.downloads.records.isEmpty {
                ContentUnavailableView("没有下载", systemImage: "arrow.down.circle", description: Text("在电影或单集详情页点「下载」，或在季页面点「下载本季」批量下载。"))
            }
            ForEach(app.downloads.records.filter { !isOffline || $0.state == .completed }) { record in
                Button { play(record) } label: { DownloadRow(record: record) }
                    .buttonStyle(.plain)
                    .disabled(app.downloads.localURL(for: record) == nil)
                    .swipeActions {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = record }
                        pauseResumeButton(record)
                    }
                    .contextMenu {
                        pauseResumeButton(record)
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = record }
                    }
            }
        }
        .navigationTitle(isOffline ? "离线" : "下载")
        .toolbar {
            if app.downloads.hasActiveDownloads {
                Button("全部暂停", systemImage: "pause.circle") { app.downloads.pauseAll() }
            } else if app.downloads.hasPausedDownloads {
                Button("全部继续", systemImage: "play.circle") { app.downloads.resumeAll() }
            }
        }
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

    @ViewBuilder
    private func pauseResumeButton(_ record: DownloadRecord) -> some View {
        switch record.state {
        case .downloading, .queued:
            Button("暂停", systemImage: "pause") { app.downloads.pause(record) }.tint(.orange)
        case .paused:
            Button("继续", systemImage: "play") { app.downloads.resume(record) }.tint(VelaTheme.accent)
        default:
            EmptyView()
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
        case .queued, .downloading, .paused:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: record.progress)
                Text("\(record.quality.title) · \(DownloadStatusText.text(record))").font(.caption).foregroundStyle(.secondary)
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

/// 详情页的下载按钮：打开下载选项（画质、音轨、空间估算）；已下载 / 下载中显示状态。
struct DownloadButton: View {
    let item: MediaItem
    /// 详情页当前选中的媒体源，用于估算大小与列出音轨。
    var source: MediaSourceInfo?
    @Environment(AppModel.self) private var app
    @State private var showsOptions = false

    var body: some View {
        let records = app.downloads.record(serverID: item.serverID, itemID: item.id)
        Button { showsOptions = true } label: {
            Image(systemName: symbol(records))
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel("下载")
        .sheet(isPresented: $showsOptions) {
            DownloadOptionsSheet(item: item, source: source)
        }
    }

    private func symbol(_ records: [DownloadRecord]) -> String {
        if records.contains(where: { $0.state == .completed }) { return "arrow.down.circle.fill" }
        if records.contains(where: { $0.state == .downloading || $0.state == .queued }) { return "arrow.down.circle.dotted" }
        if records.contains(where: { $0.state == .paused }) { return "pause.circle" }
        return "arrow.down.circle"
    }
}
