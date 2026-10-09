import SwiftUI
import VelaCore
import VelaData
import VelaDesignSystem
import VelaNetwork

/// 单个条目的下载选项（与 Android 下载对话框一致）：画质、转码时的音轨、预计大小与可用空间。
/// 原画下载服务器上的原文件（包含全部音轨），所以只有限定码率时才能选音轨。
struct DownloadOptionsSheet: View {
    let item: MediaItem
    /// 当前选中的媒体源（详情页的版本选择）；用于估算大小与列出音轨，nil 时只能按画质下载。
    let source: MediaSourceInfo?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var quality: DownloadQuality = .original
    @State private var audioIndex: Int?
    @State private var isStarting = false
    @State private var error: String?

    private var records: [DownloadRecord] { app.downloads.record(serverID: item.serverID, itemID: item.id) }
    private var audioStreams: [MediaStreamInfo] { source?.audioStreams ?? [] }
    private var choosesAudio: Bool { quality.maxBitrate != nil && audioStreams.count > 1 }
    private var estimate: Int64? {
        DownloadEstimate.bytes(quality: quality, fileSize: source?.size, sourceBitrate: source?.bitrate,
                               runTimeTicks: source?.runTimeTicks ?? item.runTimeTicks)
    }
    private var existing: DownloadRecord? { records.first { $0.quality == quality } }

    var body: some View {
        NavigationStack {
            Form {
                Section("画质") {
                    ForEach(DownloadQuality.allCases, id: \.self) { option in
                        Button { quality = option } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    if let record = records.first(where: { $0.quality == option }) {
                                        Text(DownloadStatusText.text(record)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if option == quality { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if choosesAudio {
                    Section {
                        Picker("音轨", selection: $audioIndex) {
                            Text("服务器默认").tag(Int?.none)
                            ForEach(audioStreams, id: \.index) { stream in
                                Text(stream.displayTitle ?? stream.codec?.uppercased() ?? "音轨 \(stream.index)").tag(Int?.some(stream.index))
                            }
                        }
                    } footer: {
                        Text("限定码率时由服务器转码，只保留所选音轨；原画下载包含全部音轨。")
                    }
                }
                DownloadSpaceSection(required: estimate)
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("下载")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isStarting {
                        ProgressView()
                    } else {
                        Button("开始下载") { Task { await start() } }
                            .disabled(!canStart)
                    }
                }
            }
        }
        .onAppear { audioIndex = source?.defaultAudioStreamIndex }
    }

    private var canStart: Bool {
        if let existing, existing.state != .failed { return false }
        return !DownloadSpace.exceedsAvailable(estimate)
    }

    private func start() async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let audio = choosesAudio ? audioIndex : nil
            let resolved = try await app.playbackResolver.resolveDownload(
                item: item, client: client, quality: quality, capabilities: app.capabilities, audioStreamIndex: audio
            )
            app.downloads.enqueue(item: item, source: resolved, quality: quality,
                                  posterURL: app.imageURL(for: item, kind: .primary, maxWidth: 300), audioStreamIndex: audio)
            dismiss()
        } catch {
            self.error = "无法开始下载：\(error.localizedDescription)"
        }
    }
}

/// 整季（或全剧）批量下载：选择单集、画质与音轨语言，按预计大小检查可用空间后逐集加入下载队列。
struct SeasonDownloadSheet: View {
    let seriesID: String
    let seasonID: String?
    let title: String
    let serverID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: LoadState<[ItemWithMediaSource]> = .idle
    @State private var selection: Set<String> = []
    @State private var quality: DownloadQuality = .original
    /// 音轨语言（ISO 639 代码）；nil 为服务器默认。按语言而不是序号选：各集的音轨序号可能不同。
    @State private var audioLanguage: String?
    @State private var progress: (done: Int, total: Int)?
    @State private var failures: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                switch episodes {
                case .loaded(let all):
                    content(all)
                case .failed(let message):
                    LoadFailureView(message: message) { Task { await load() } }
                default:
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let progress {
                        Text("\(progress.done)/\(progress.total)").monospacedDigit()
                    } else {
                        Button("下载 \(selection.count) 集") { Task { await start() } }
                            .disabled(!canStart)
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ all: [ItemWithMediaSource]) -> some View {
        Section {
            Picker("画质", selection: $quality) {
                ForEach(DownloadQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if quality.maxBitrate != nil, !languages(all).isEmpty {
                Picker("音轨语言", selection: $audioLanguage) {
                    Text("服务器默认").tag(String?.none)
                    ForEach(languages(all), id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(String?.some(code))
                    }
                }
            }
        } footer: {
            if quality.maxBitrate != nil {
                Text("限定码率时由服务器转码，只保留所选语言的音轨；没有该语言的单集使用服务器默认音轨。")
            }
        }
        Section {
            ForEach(all) { entry in
                let downloaded = isDownloaded(entry)
                Toggle(isOn: Binding(
                    get: { selection.contains(entry.id) },
                    set: { selected in
                        if selected { selection.insert(entry.id) } else { selection.remove(entry.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([entry.item.episodeLabel, entry.item.name].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                        Text(downloaded ? "已下载 / 下载中" : estimate(entry).map(DownloadSpace.format) ?? "大小未知")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(downloaded || progress != nil)
            }
        } header: {
            HStack {
                Text("单集")
                Spacer()
                let selectable = all.filter { !isDownloaded($0) }.map(\.id)
                Button(selection.count == selectable.count ? "全不选" : "全选") {
                    selection = selection.count == selectable.count ? [] : Set(selectable)
                }
                .font(.caption)
                .disabled(progress != nil)
            }
        }
        DownloadSpaceSection(required: selectedEstimate(all))
        if !failures.isEmpty {
            Section("未能加入下载") {
                ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var canStart: Bool {
        guard progress == nil, !selection.isEmpty, let all = episodes.value else { return false }
        return !DownloadSpace.exceedsAvailable(selectedEstimate(all))
    }

    private func languages(_ all: [ItemWithMediaSource]) -> [String] {
        var seen: [String] = []
        for code in all.flatMap({ $0.source?.audioStreams ?? [] }).compactMap(\.language) where !seen.contains(code) {
            seen.append(code)
        }
        return seen
    }

    private func isDownloaded(_ entry: ItemWithMediaSource) -> Bool {
        app.downloads.record(serverID: serverID, itemID: entry.id).contains { $0.quality == quality && $0.state != .failed }
    }

    private func estimate(_ entry: ItemWithMediaSource) -> Int64? {
        DownloadEstimate.bytes(quality: quality, fileSize: entry.source?.size, sourceBitrate: entry.source?.bitrate,
                               runTimeTicks: entry.source?.runTimeTicks ?? entry.item.runTimeTicks)
    }

    /// 已选单集的预计总大小；任一集大小未知时仍按已知部分合计（与 Android 相同，未知按 0 计）。
    private func selectedEstimate(_ all: [ItemWithMediaSource]) -> Int64? {
        let selected = all.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        return selected.compactMap(estimate).reduce(0, +)
    }

    private func load() async {
        guard let client = app.client(forServerID: serverID) else { return }
        episodes = .loading
        let result = await capture { try await client.episodesWithMediaSources(seriesID: seriesID, seasonID: seasonID) }
        episodes = LoadState(result)
        // 默认选中未看过、未下载的单集。
        if case .success(let all) = result {
            selection = Set(all.filter { !$0.item.isPlayed && !isDownloaded($0) }.map(\.id))
        }
    }

    private func start() async {
        guard let client = app.client(forServerID: serverID), let all = episodes.value else { return }
        let targets = all.filter { selection.contains($0.id) }
        failures = []
        progress = (0, targets.count)
        // 逐集解析：每集一次 PlaybackInfo，避免同时为整季启动转码会话。
        for (offset, entry) in targets.enumerated() {
            let audio = quality.maxBitrate == nil ? nil : audioLanguage.flatMap { language in
                entry.source?.audioStreams.first { $0.language == language }?.index
            }
            do {
                let resolved = try await app.playbackResolver.resolveDownload(
                    item: entry.item, client: client, quality: quality, capabilities: app.capabilities, audioStreamIndex: audio
                )
                app.downloads.enqueue(item: entry.item, source: resolved, quality: quality,
                                      posterURL: app.imageURL(for: entry.item, kind: .primary, maxWidth: 300), audioStreamIndex: audio)
            } catch {
                failures.append("\(entry.item.episodeLabel ?? entry.item.name)：\(error.localizedDescription)")
            }
            progress = (offset + 1, targets.count)
        }
        progress = nil
        if failures.isEmpty { dismiss() }
    }
}

/// 预计大小与可用空间（与 Android 的「可用 / 已选 / 剩余或超出」一致）。
private struct DownloadSpaceSection: View {
    let required: Int64?

    var body: some View {
        let available = DownloadManager.availableCapacity()
        Section {
            LabeledContent("预计大小", value: required.map(DownloadSpace.format) ?? "未知")
            if let available {
                LabeledContent("可用空间", value: DownloadSpace.format(available))
                if let required {
                    if required > available {
                        LabeledContent("超出", value: DownloadSpace.format(required - available))
                            .foregroundStyle(.red)
                    } else {
                        LabeledContent("下载后剩余", value: DownloadSpace.format(available - required))
                    }
                }
            }
        } footer: {
            if let required, let available, required > available {
                Text("空间不足，请减少选择或清理存储空间后再试。")
            } else if required == nil {
                Text("服务器未提供文件大小或时长，无法估算。")
            }
        }
    }
}

enum DownloadSpace {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 预计大小已知且超过可用空间时不允许开始；未知时不拦截（与 Android 一致）。
    static func exceedsAvailable(_ required: Int64?) -> Bool {
        guard let required, let available = DownloadManager.availableCapacity() else { return false }
        return required > available
    }
}

enum DownloadStatusText {
    static func text(_ record: DownloadRecord) -> String {
        switch record.state {
        case .completed: "已下载"
        case .failed: "失败，可重新下载"
        case .paused: "已暂停 \(Int(record.progress * 100))%"
        case .queued, .downloading: "下载中 \(Int(record.progress * 100))%"
        }
    }
}
