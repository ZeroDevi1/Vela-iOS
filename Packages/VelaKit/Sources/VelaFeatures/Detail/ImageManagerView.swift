import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VelaCore
import VelaDesignSystem
import VelaNetwork

private enum ManagedImageType: String, CaseIterable, Identifiable, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case screenshot = "Screenshot"
    case logo = "Logo"
    case thumb = "Thumb"
    case banner = "Banner"
    case art = "Art"
    case disc = "Disc"

    var id: Self { self }

    var title: String {
        switch self {
        case .primary: "海报"
        case .backdrop: "背景图"
        case .screenshot: "剧照"
        case .logo: "标志"
        case .thumb: "缩略图"
        case .banner: "横幅"
        case .art: "艺术图"
        case .disc: "光盘"
        }
    }

    var allowsMultiple: Bool { self == .backdrop || self == .screenshot }
}

struct ImageManagerView: View {
    let item: MediaItem
    let onChange: () -> Void
    @Environment(AppModel.self) private var app
    @State private var images: LoadState<[ItemImageInfo]> = .idle
    @State private var revision = UUID()
    @State private var loadedRevision = UUID()
    @State private var pendingDelete: ItemImageInfo?
    @State private var preview: ImagePreviewSelection?
    @State private var saving = false
    @State private var refreshing = false
    @State private var error: String?

    private static let maxUploadBytes = 20 * 1024 * 1024

    private var isBusy: Bool { saving || refreshing }
    private var client: MediaServerClient? { app.client(forServerID: item.serverID) }
    private var types: [ManagedImageType] {
        ManagedImageType.allCases.filter { $0 != .screenshot || client?.kind == .emby }
    }

    var body: some View {
        Form {
            NavigationLink {
                RemoteImagePicker(item: item, types: types, initialType: .primary, onApplied: didChange)
            } label: {
                Label("搜索图片", systemImage: "magnifyingglass")
            }
            .disabled(isBusy)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            switch images {
            case .loaded(let list):
                ForEach(types) { type in
                    let current = list.filter { $0.type == type.rawValue }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
                    imageSection(type, images: current)
                        .disabled(isBusy)
                }
            case .failed(let message):
                LoadFailureView(message: message) { reload() }
            default:
                ProgressView("正在加载图片…")
            }
        }
        .navigationTitle("编辑图片")
        .toolbar {
            if isBusy {
                ToolbarItem {
                    ProgressView().controlSize(.small).accessibilityLabel("正在更新图片")
                }
            }
        }
        .task(id: revision) { [revision] in await load(revision: revision) }
        .imagePreview($preview)
        .confirmationDialog(
            "删除这张图片？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let image = pendingDelete {
                Button("删除", role: .destructive) { Task { await delete(image) } }
            }
        }
    }

    private func imageSection(_ type: ManagedImageType, images: [ItemImageInfo]) -> some View {
        Section {
            ForEach(Array(images.enumerated()), id: \.element.id) { position, image in
                let previousIndex = position > 0 ? images[position - 1].index : nil
                let nextIndex = position + 1 < images.count ? images[position + 1].index : nil
                imageRow(image, type: type, previousIndex: previousIndex, nextIndex: nextIndex, canReorder: images.count > 1)
            }
            NavigationLink {
                RemoteImagePicker(item: item, types: types, initialType: type, onApplied: didChange)
            } label: {
                Label("搜索\(type.title)", systemImage: "magnifyingglass")
            }
            PhotosPicker(selection: Binding(get: { nil }, set: { selection in
                if let selection { Task { await upload(selection, type: type) } }
            }), matching: .images) {
                Label("上传本地图片", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text(type.title)
        } footer: {
            if type == .backdrop && images.count > 1 {
                Text("用箭头调整顺序。详情页使用排在第一张的背景图。")
            }
        }
    }

    private func imageRow(
        _ image: ItemImageInfo, type: ManagedImageType, previousIndex: Int?, nextIndex: Int?, canReorder: Bool
    ) -> some View {
        HStack {
            let thumbnail = imageURL(for: image, maxWidth: 300)
            Button {
                if let url = imageURL(for: image, maxWidth: 1920) {
                    preview = ImagePreviewSelection(url: url, thumbnailURL: thumbnail)
                }
            } label: {
                CachedImage(url: thumbnail, contentMode: .fit) { Color.secondary.opacity(0.2) }
                    .frame(width: 108, height: 64)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("查看\(type.title)")

            VStack(alignment: .leading) {
                if type.allowsMultiple, let index = image.index {
                    Text("第 \(index + 1) 张").font(.subheadline)
                }
                if let width = image.width, let height = image.height {
                    Text("\(width)×\(height)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if type.allowsMultiple && canReorder {
                reorderButton("上移", systemImage: "arrow.up", image: image, target: previousIndex)
                reorderButton("下移", systemImage: "arrow.down", image: image, target: nextIndex)
            }
            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = image }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func reorderButton(_ label: String, systemImage: String, image: ItemImageInfo, target: Int?) -> some View {
        Button(label, systemImage: systemImage) {
            guard let index = image.index, let target else { return }
            Task {
                await save(failureTitle: "调整顺序失败") { client in
                    try await client.updateImageIndex(itemID: item.id, type: image.type, index: index, newIndex: target)
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(image.index == nil || target == nil || image.index == target)
    }

    private func imageURL(for image: ItemImageInfo, maxWidth: Int) -> URL? {
        guard let url = client?.imageURL(itemID: item.id, image: image, maxWidth: maxWidth) else { return nil }
        if image.tag?.isEmpty == false { return url }
        // 某些 Emby 版本不返回 ImageTag；重排后原索引的缓存不能继续使用。
        return url.appending(queryItems: [URLQueryItem(name: "v", value: loadedRevision.uuidString)])
    }

    private func load(revision: UUID) async {
        guard !Task.isCancelled, revision == self.revision else { return }
        guard let client else {
            images = .failed("无法连接媒体服务器。")
            refreshing = false
            return
        }
        refreshing = true
        if images.value == nil { images = .loading }
        let itemID = item.id
        let result = await capture { try await client.itemImages(itemID: itemID) }
        guard !Task.isCancelled, revision == self.revision else { return }
        refreshing = false
        loadedRevision = revision
        images = LoadState(result)
    }

    private func reload() {
        refreshing = true
        revision = UUID()
    }

    private func didChange() {
        reload()
        onChange()
    }

    private func save(failureTitle: String, action: @MainActor (MediaServerClient) async throws -> Void) async {
        guard !isBusy, let client else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await action(client)
            didChange()
        } catch {
            self.error = "\(failureTitle)：\(error.localizedDescription)"
        }
    }

    private func upload(_ selection: PhotosPickerItem, type: ManagedImageType) async {
        await save(failureTitle: "上传失败") { client in
            guard let data = try await selection.loadTransferable(type: Data.self), !data.isEmpty else {
                throw UploadError.unreadable
            }
            guard data.count <= Self.maxUploadBytes else { throw UploadError.tooLarge }
            let mime = selection.supportedContentTypes.lazy.compactMap(\.preferredMIMEType)
                .first { $0.hasPrefix("image/") } ?? "image/jpeg"
            try await client.uploadImage(itemID: item.id, type: type.rawValue, data: data, mimeType: mime)
        }
    }

    private func delete(_ image: ItemImageInfo) async {
        await save(failureTitle: "删除失败") { client in
            try await client.deleteImage(itemID: item.id, type: image.type, index: image.index)
        }
    }

    private enum UploadError: LocalizedError {
        case unreadable, tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取这张图片。"
            case .tooLarge: "图片超过 20 MB。"
            }
        }
    }
}

private struct RemoteImagePicker: View {
    let item: MediaItem
    let types: [ManagedImageType]
    let onApplied: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var request: Request
    @State private var images: LoadState<[RemoteImageInfo]> = .idle
    @State private var providers: [String] = []
    @State private var nextIndex: Int?
    @State private var loadingMore = false
    @State private var applying: String?
    @State private var error: String?
    @State private var preview: ImagePreviewSelection?

    private static let pageSize = 24

    private struct Query: Hashable, Sendable {
        var type: ManagedImageType
        var provider: String?
        var allLanguages = false
    }

    private struct Request: Hashable, Sendable {
        let id = UUID()
        let query: Query
        var offset = 0
    }

    init(item: MediaItem, types: [ManagedImageType], initialType: ManagedImageType, onApplied: @escaping () -> Void) {
        self.item = item
        self.types = types
        self.onApplied = onApplied
        _request = State(initialValue: Request(query: Query(type: initialType)))
    }

    var body: some View {
        let request = request
        VStack(spacing: 0) {
            filters
                .padding()
                .disabled(applying != nil)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding([.horizontal, .bottom])
            }
            Divider()
            ScrollView {
                VStack(spacing: VelaTheme.Spacing.m) {
                    results
                }
                .padding()
            }
            .id(request.query)
        }
        .navigationTitle("搜索图片")
        .task(id: request) { await load(request) }
        .imagePreview($preview)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Picker("图片类型", selection: Binding(get: { request.query.type }, set: { type in
                guard type != request.query.type else { return }
                providers = []
                search(Query(type: type, allLanguages: request.query.allLanguages))
            })) {
                ForEach(types) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            if !providers.isEmpty {
                Picker("提供方", selection: Binding(get: { request.query.provider }, set: { provider in
                    var query = request.query
                    query.provider = provider
                    search(query)
                })) {
                    Text("全部").tag(String?.none)
                    ForEach(providers, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
            }
            Toggle("显示全部语言", isOn: Binding(get: { request.query.allLanguages }, set: { allLanguages in
                var query = request.query
                query.allLanguages = allLanguages
                search(query)
            }))
        }
    }

    @ViewBuilder
    private var results: some View {
        switch images {
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView("没有可用的图片", systemImage: "photo")
        case .loaded(let list):
            let type = request.query.type
            LazyVGrid(columns: [GridItem(.adaptive(minimum: type == .primary ? 110 : 158), spacing: 12)], spacing: 12) {
                ForEach(list) { image in candidate(image, type: type) }
            }
            if let nextIndex {
                Button {
                    loadingMore = true
                    error = nil
                    request = Request(query: request.query, offset: nextIndex)
                } label: {
                    if loadingMore { ProgressView() } else { Text("加载更多") }
                }
                .buttonStyle(.bordered)
                .disabled(loadingMore || applying != nil)
            }
        case .failed(let message):
            LoadFailureView(message: message) { search(request.query) }
        default:
            ProgressView().frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private func candidate(_ image: RemoteImageInfo, type: ManagedImageType) -> some View {
        let url = URL(string: image.url)
        let thumbnail = image.thumbnailURL.flatMap(URL.init(string:)) ?? url
        return VStack(spacing: 6) {
            Button {
                if let url { preview = ImagePreviewSelection(url: url, thumbnailURL: thumbnail) }
            } label: {
                Color.secondary.opacity(0.12)
                    .aspectRatio(type == .primary ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
                    .overlay { CachedImage(url: thumbnail, contentMode: .fit) { Image(systemName: "photo") } }
                    .clipShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .accessibilityLabel("预览\(type.title)")

            let dimensions = if let width = image.width, let height = image.height { "\(width)×\(height)" } else { "" }
            Text([image.providerName, image.language, dimensions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                Task { await apply(image, type: type) }
            } label: {
                if applying == image.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label(type.allowsMultiple ? "添加图片" : "使用此图", systemImage: "arrow.down")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(url == nil)
        }
        .disabled(applying != nil)
    }

    private func search(_ query: Query) {
        images = .loading
        nextIndex = nil
        loadingMore = false
        error = nil
        request = Request(query: query)
    }

    private func load(_ request: Request) async {
        guard !Task.isCancelled, request == self.request else { return }
        guard let client = app.client(forServerID: item.serverID) else {
            if request.offset == 0 { images = .failed("无法连接媒体服务器。") }
            else { error = "无法连接媒体服务器。" }
            loadingMore = false
            return
        }
        let query = request.query
        let itemID = item.id
        let limit = Self.pageSize
        let result = await capture {
            try await client.remoteImages(
                itemID: itemID, type: query.type.rawValue, providerName: query.provider, allLanguages: query.allLanguages,
                startIndex: request.offset, limit: limit
            )
        }
        guard !Task.isCancelled, request == self.request else { return }
        loadingMore = false
        switch result {
        case .success(let value):
            if query.provider == nil { providers = value.providers.sorted() }
            var current = request.offset == 0 ? [] : images.value ?? []
            var seen = Set(current.map(\.id))
            let unique = value.images.filter { seen.insert($0.id).inserted }
            current.append(contentsOf: unique)
            images = .loaded(current)

            // 分页偏移按服务器返回的条数计算，不能用去重后的网格数量。
            let end = request.offset + value.images.count
            let hasMore = value.totalRecordCount.map { end < $0 } ?? (value.images.count == limit && !unique.isEmpty)
            nextIndex = hasMore && !value.images.isEmpty ? end : nil
        case .failure(let failure):
            if request.offset == 0 { images = .failed(failure.localizedDescription) }
            else { error = "加载更多失败：\(failure.localizedDescription)" }
        }
    }

    private func apply(_ image: RemoteImageInfo, type: ManagedImageType) async {
        guard applying == nil, type == request.query.type else { return }
        guard let client = app.client(forServerID: item.serverID) else {
            error = "无法连接媒体服务器。"
            return
        }
        applying = image.id
        error = nil
        defer { applying = nil }
        do {
            try await client.downloadRemoteImage(itemID: item.id, type: type.rawValue, image: image)
            onApplied()
            dismiss()
        } catch {
            self.error = "设置失败：\(error.localizedDescription)"
        }
    }
}
