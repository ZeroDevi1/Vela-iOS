import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VelaCore
import VelaDesignSystem
import VelaNetwork

/// 管理员的元数据管理（与 Android 版元数据页一致）：编辑基本信息、识别、图片管理、字幕管理。
/// 只在详情页「更多」菜单中对管理员显示；所有写操作提交到服务器后即对所有客户端生效。
struct MetadataManagerView: View {
    let item: MediaItem
    /// 详情页当前选中的媒体源：字幕管理按它列出与删除外挂字幕。
    let mediaSource: MediaSourceInfo?
    /// 有修改时回调，详情页据此重新加载。
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { MetadataEditView(item: item, onChange: onChange) } label: {
                    Label("编辑元数据", systemImage: "pencil")
                }
                if MediaServerClient.remoteSearchType(for: item.kind) != nil {
                    NavigationLink { IdentifyView(item: item, onChange: onChange) } label: {
                        Label("识别", systemImage: "magnifyingglass")
                    }
                }
                NavigationLink { ImageManagerView(item: item, onChange: onChange) } label: {
                    Label("编辑图片", systemImage: "photo.on.rectangle")
                }
                if item.kind.isPlayable {
                    NavigationLink { SubtitleManagerView(item: item, mediaSource: mediaSource, onChange: onChange) } label: {
                        Label("管理字幕", systemImage: "captions.bubble")
                    }
                }
            }
            .navigationTitle(item.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 编辑

private struct MetadataEditView: View {
    let item: MediaItem
    let onChange: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: EditableMetadata?
    @State private var original: EditableMetadata?
    @State private var error: String?
    @State private var isSaving = false
    @State private var confirmRefresh = false

    var body: some View {
        Form {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if let binding = Binding($metadata) {
                Section("基本信息") {
                    TextField("标题", text: binding.name)
                    TextField("原标题", text: binding.originalTitle)
                    TextField("排序标题", text: binding.sortName)
                    TextField("年份", value: binding.productionYear, format: .number.grouping(.never))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("分级", text: binding.officialRating)
                    TextField("评分", value: binding.communityRating, format: .number.precision(.fractionLength(0...1)))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                Section("简介") {
                    TextField("简介", text: binding.overview, axis: .vertical).lineLimit(4...12)
                }
                Section {
                    TextField("类型", text: listBinding(binding.genres))
                    TextField("标签", text: listBinding(binding.tags))
                    TextField("制片公司", text: listBinding(binding.studios))
                } footer: {
                    Text("多个值用逗号分隔。")
                }
                Section {
                    Toggle("锁定元数据", isOn: binding.lockData)
                } footer: {
                    Text("锁定后服务器刷新元数据时不会覆盖这里的修改。")
                }
                Section {
                    Button("从元数据提供方刷新…", systemImage: "arrow.clockwise") { confirmRefresh = true }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("编辑元数据")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存") { Task { await save() } }.disabled(metadata == nil || metadata == original)
                }
            }
        }
        .confirmationDialog("刷新元数据", isPresented: $confirmRefresh, titleVisibility: .visible) {
            Button("补充缺失的元数据") { Task { await refresh(replaceAll: false) } }
            Button("替换全部元数据与图片", role: .destructive) { Task { await refresh(replaceAll: true) } }
        } message: {
            Text("替换全部会覆盖未锁定的字段与现有图片。")
        }
        .task { await load() }
    }

    private func listBinding(_ list: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { list.wrappedValue.joined(separator: ", ") },
            set: { text in
                list.wrappedValue = text.split(whereSeparator: { $0 == "," || $0 == "，" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func load() async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        do {
            let loaded = try await client.editableMetadata(itemID: item.id)
            metadata = loaded
            original = loaded
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let client = app.client(forServerID: item.serverID), let metadata else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.updateMetadata(itemID: item.id, metadata)
            original = metadata
            onChange()
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }

    private func refresh(replaceAll: Bool) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        do {
            try await client.refreshMetadata(itemID: item.id, replaceAll: replaceAll)
            error = nil
            onChange()
        } catch {
            self.error = "刷新失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 识别

private struct IdentifyView: View {
    let item: MediaItem
    let onChange: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var year: Int?
    /// 外部 ID 输入框，来自服务器的 `ExternalIdInfos`（含插件提供方）；取不到时退回 TMDB / IMDb。
    @State private var idFields: [ExternalIDInfo] = []
    /// 提供方键 → 输入的 ID。
    @State private var ids: [String: String] = [:]
    @State private var loadedFields = false
    @State private var results: LoadState<[RemoteMetadataResult]> = .idle
    @State private var replaceImages = true
    @State private var pending: RemoteMetadataResult?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                TextField("年份", value: $year, format: .number.grouping(.never))
                ForEach(idFields) { field in
                    TextField(Self.label(field), text: Binding(get: { ids[field.id] ?? "" }, set: { ids[field.id] = $0 }))
                        .autocorrectionDisabled()
                }
                Button("搜索", systemImage: "magnifyingglass") { Task { await search() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty && filledIDs.isEmpty)
            } footer: {
                Text("按名称与年份搜索，或填写外部 ID 精确匹配。")
            }
            Section {
                Toggle("替换现有图片", isOn: $replaceImages)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            switch results {
            case .loaded(let list) where list.isEmpty:
                Section { Text("没有找到匹配的条目").foregroundStyle(.secondary) }
            case .loaded(let list):
                Section("搜索结果") {
                    ForEach(list) { result in
                        Button { pending = result } label: { ResultRow(result: result) }
                            .buttonStyle(.plain)
                    }
                }
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let message):
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            case .idle:
                EmptyView()
            }
        }
        .navigationTitle("识别")
        .onAppear {
            if name.isEmpty {
                name = item.name
                year = item.productionYear
            }
        }
        .task { await loadFields() }
        .confirmationDialog(
            "将「\(item.name)」识别为「\(pending?.name ?? "")」？",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("应用") { if let pending { Task { await apply(pending) } } }
        } message: {
            Text("服务器会按新的外部 ID 重新获取元数据\(replaceImages ? "并替换图片" : "")。")
        }
    }

    private func search() async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        results = .loading
        let providerIDs = filledIDs
        let (itemID, kind, name, year) = (item.id, item.kind, name, year)
        results = LoadState(await capture {
            try await client.remoteMetadataSearch(itemID: itemID, kind: kind, name: name, year: year, providerIDs: providerIDs)
        })
    }

    private var filledIDs: [String: String] {
        ids.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// 「TMDB Id」；Jellyfin 同一提供方有多种实体类型时附上类型（如「TheMovieDb Id · Movie」）。
    private static func label(_ field: ExternalIDInfo) -> String {
        let base = "\(field.name ?? field.key ?? "") Id"
        guard let type = field.type, !type.isEmpty else { return base }
        return "\(base) · \(type)"
    }

    /// 取外部 ID 输入框并预填条目现有的 ID（映射时键已转小写，按小写匹配）。只在首次出现时执行。
    private func loadFields() async {
        guard !loadedFields, let client = app.client(forServerID: item.serverID) else { return }
        loadedFields = true
        var fields = (try? await client.externalIDInfos(itemID: item.id)) ?? []
        if fields.isEmpty {
            fields = [ExternalIDInfo(name: "TMDB", key: "Tmdb"), ExternalIDInfo(name: "IMDb", key: "Imdb")]
        }
        // Jellyfin 可能对同一键返回多种实体类型，ID 只按键提交，同键只保留一个输入框。
        var seen: Set<String> = []
        idFields = fields.filter { seen.insert($0.id.lowercased()).inserted }
        for field in idFields where ids[field.id] == nil {
            ids[field.id] = item.providerIDs[field.id.lowercased()] ?? ""
        }
    }

    private func apply(_ result: RemoteMetadataResult) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        do {
            try await client.applyRemoteMetadata(itemID: item.id, result: result, replaceAllImages: replaceImages)
            onChange()
            dismiss()
        } catch {
            self.error = "应用失败：\(error.localizedDescription)"
        }
    }

    private struct ResultRow: View {
        let result: RemoteMetadataResult

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                RemoteArtwork(url: result.imageURL, placeholderSymbol: "film")
                    .frame(width: 50, height: 75)
                    .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text([result.name, result.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                    if let provider = result.providerName {
                        Text(provider).font(.caption).foregroundStyle(.secondary)
                    }
                    if let overview = result.overview {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .contentShape(.rect)
        }
    }
}

// MARK: - 图片

private struct ImageManagerView: View {
    let item: MediaItem
    let onChange: () -> Void
    @Environment(AppModel.self) private var app
    @State private var images: LoadState<[ItemImageInfo]> = .idle
    @State private var pendingDelete: ItemImageInfo?
    @State private var error: String?
    /// 正在上传的图片类型；上传期间其余上传入口禁用。
    @State private var uploadingType: String?

    /// 可替换的图片类型（与 Android 相同）。
    static let types: [(String, String)] = [
        ("Primary", "海报"), ("Backdrop", "背景"), ("Logo", "标志"), ("Thumb", "缩略图"),
        ("Banner", "横幅"), ("Art", "艺术图"), ("Disc", "光盘")
    ]

    /// 单张图片超过该大小（字节）不上传：服务器要求 Base64 请求体，过大的图会让请求体膨胀。与 Android 版相同。
    private static let maxUploadBytes = 20 * 1024 * 1024

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(Self.types, id: \.0) { type, title in
                Section {
                    let current = (images.value ?? []).filter { $0.type == type }
                    ForEach(current) { image in
                        HStack {
                            CachedImage(url: app.client(forServerID: item.serverID)?.imageURL(itemID: item.id, image: image, maxWidth: 300),
                                        contentMode: .fit) { Color.secondary.opacity(0.2) }
                                .frame(width: 120, height: 70)
                            if let width = image.width, let height = image.height {
                                Text("\(width)×\(height)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = image }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    NavigationLink {
                        RemoteImagePicker(item: item, type: type, title: title) {
                            onChange()
                            Task { await load() }
                        }
                    } label: {
                        Label(current.isEmpty ? "搜索\(title)" : (type == "Backdrop" ? "搜索并添加\(title)" : "搜索并更换\(title)"), systemImage: "magnifyingglass")
                    }
                    PhotosPicker(selection: Binding(get: { nil }, set: { selection in
                        if let selection { Task { await upload(selection, type: type) } }
                    }), matching: .images) {
                        HStack {
                            Label("上传本地图片", systemImage: "square.and.arrow.up")
                            if uploadingType == type { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(uploadingType != nil)
                } header: {
                    Text(title)
                }
            }
        }
        .navigationTitle("图片")
        .task { await load() }
        .confirmationDialog("删除这张图片？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let image = pendingDelete { Task { await delete(image) } } }
        }
    }

    private func load() async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        images = LoadState(await capture { try await client.itemImages(itemID: item.id) })
    }

    /// 把相册中选中的图片上传为该类型的图片。
    private func upload(_ selection: PhotosPickerItem, type: String) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        uploadingType = type
        defer { uploadingType = nil }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self), !data.isEmpty else {
                error = "无法读取这张图片。"
                return
            }
            guard data.count <= Self.maxUploadBytes else {
                error = "图片超过 20 MB，无法上传。"
                return
            }
            // 优先用照片自带的类型（HEIC / PNG …）；取不到时按 JPEG 提交。
            let mime = selection.supportedContentTypes.lazy.compactMap(\.preferredMIMEType).first { $0.hasPrefix("image/") } ?? "image/jpeg"
            try await client.uploadImage(itemID: item.id, type: type, data: data, mimeType: mime)
            error = nil
            onChange()
            await load()
        } catch {
            self.error = "上传失败：\(error.localizedDescription)"
        }
    }

    private func delete(_ image: ItemImageInfo) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        do {
            try await client.deleteImage(itemID: item.id, type: image.type, index: image.type == "Backdrop" ? image.index : nil)
            onChange()
            await load()
        } catch {
            self.error = "删除失败：\(error.localizedDescription)"
        }
    }
}

private struct RemoteImagePicker: View {
    let item: MediaItem
    let type: String
    let title: String
    let onApplied: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var images: LoadState<[RemoteImageInfo]> = .idle
    /// 服务器返回的可选提供方；首次查询（全部提供方）时填充，之后切换筛选不变。
    @State private var providers: [String] = []
    /// 选中的提供方；nil 为全部。
    @State private var provider: String?
    @State private var allLanguages = false
    @State private var applying: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                if providers.count > 1 {
                    Picker("提供方", selection: $provider) {
                        Text("全部").tag(String?.none)
                        ForEach(providers, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                }
                Toggle("显示全部语言", isOn: $allLanguages).padding(.horizontal)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal)
                }
                switch images {
                case .loaded(let list) where list.isEmpty:
                    ContentUnavailableView("没有可用的图片", systemImage: "photo")
                case .loaded(let list):
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: type == "Primary" ? 110 : 180), spacing: 12)], spacing: 12) {
                        ForEach(list) { image in
                            Button { Task { await apply(image) } } label: {
                                VStack(spacing: 4) {
                                    RemoteArtwork(url: URL(string: image.thumbnailURL ?? image.url), placeholderSymbol: "photo")
                                        .aspectRatio(type == "Primary" ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                                        .clipShape(.rect(cornerRadius: 6))
                                        .overlay { if applying == image.id { ProgressView() } }
                                    Text([image.providerName, image.language, image.width.map { "\($0)px" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(applying != nil)
                        }
                    }
                    .padding(.horizontal)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding()
                default:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("搜索\(title)")
        .task(id: Query(provider: provider, allLanguages: allLanguages)) { await load() }
    }

    private struct Query: Hashable {
        var provider: String?
        var allLanguages: Bool
    }

    private func load() async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        images = .loading
        let (itemID, type, provider, allLanguages) = (item.id, type, provider, allLanguages)
        let result = await capture { try await client.remoteImages(itemID: itemID, type: type, providerName: provider, allLanguages: allLanguages) }
        if case .success(let value) = result, providers.isEmpty { providers = value.providers }
        images = LoadState(result.map(\.images))
    }

    private func apply(_ image: RemoteImageInfo) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        applying = image.id
        defer { applying = nil }
        do {
            try await client.downloadRemoteImage(itemID: item.id, type: type, image: image)
            onApplied()
            dismiss()
        } catch {
            self.error = "设置失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 字幕

private struct SubtitleManagerView: View {
    let item: MediaItem
    let mediaSource: MediaSourceInfo?
    let onChange: () -> Void
    @Environment(AppModel.self) private var app
    @State private var language = "chi"
    @State private var results: LoadState<[RemoteSubtitle]> = .idle
    @State private var downloading: String?
    @State private var deleted: Set<Int> = []
    @State private var pendingDelete: MediaStreamInfo?
    @State private var message: String?

    /// 常用字幕语言（ISO 639-2，与服务器字幕插件一致）。
    private static let languages: [(String, String)] = [("chi", "中文"), ("eng", "英语"), ("jpn", "日语"), ("kor", "韩语"), ("fre", "法语"), ("ger", "德语"), ("spa", "西班牙语")]

    private var externalSubtitles: [MediaStreamInfo] {
        (mediaSource?.subtitleStreams ?? []).filter { $0.isExternal == true && !deleted.contains($0.index) }
    }

    var body: some View {
        Form {
            if let message {
                Section { Label(message, systemImage: "info.circle") }
            }
            Section {
                if externalSubtitles.isEmpty {
                    Text("没有外挂字幕").foregroundStyle(.secondary)
                }
                ForEach(externalSubtitles, id: \.index) { stream in
                    HStack {
                        Text(stream.displayTitle ?? stream.title ?? "字幕 \(stream.index)")
                        Spacer()
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = stream }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("外挂字幕")
            } footer: {
                Text("内嵌字幕属于视频文件，不能在这里删除。")
            }
            Section("在线搜索") {
                Picker("语言", selection: $language) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Button("搜索", systemImage: "magnifyingglass") { Task { await search() } }
                switch results {
                case .loaded(let list) where list.isEmpty:
                    Text("没有找到字幕").foregroundStyle(.secondary)
                case .loaded(let list):
                    ForEach(list) { subtitle in
                        Button { Task { await download(subtitle) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(subtitle.name ?? subtitle.id).lineLimit(2)
                                    Text([subtitle.providerName, subtitle.format, subtitle.isHashMatch == true ? "哈希匹配" : nil,
                                          subtitle.downloadCount.map { "\($0) 次下载" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if downloading == subtitle.id { ProgressView() }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(downloading != nil)
                    }
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }
        }
        .navigationTitle("字幕")
        .confirmationDialog("删除字幕「\(pendingDelete?.displayTitle ?? "")」？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let stream = pendingDelete { Task { await delete(stream) } } }
        } message: {
            Text("将删除服务器上的字幕文件。")
        }
    }

    private func search() async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        results = .loading
        results = LoadState(await capture {
            try await client.searchRemoteSubtitles(itemID: item.id, mediaSourceID: mediaSource?.id, language: language)
        })
    }

    private func download(_ subtitle: RemoteSubtitle) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        downloading = subtitle.id
        defer { downloading = nil }
        do {
            try await client.downloadRemoteSubtitle(itemID: item.id, subtitleID: subtitle.id)
            message = "已下载「\(subtitle.name ?? subtitle.id)」，服务器刷新后出现在字幕列表中"
            onChange()
        } catch {
            message = "下载失败：\(error.localizedDescription)"
        }
    }

    private func delete(_ stream: MediaStreamInfo) async {
        guard let client = app.client(forServerID: item.serverID) else { return }
        do {
            try await client.deleteSubtitle(itemID: item.id, mediaSourceID: mediaSource?.id, streamIndex: stream.index)
            deleted.insert(stream.index)
            message = "已删除字幕"
            onChange()
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
    }
}
