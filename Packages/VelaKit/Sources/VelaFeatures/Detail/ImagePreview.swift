import SwiftUI
import VelaCore
import VelaDesignSystem
import VelaNetwork

struct ImagePreviewPage: Identifiable {
    let id: String
    let previewURL: URL
    let thumbnailURL: URL?
}

struct ImagePreviewSelection: Identifiable {
    let id = UUID()
    let pages: [ImagePreviewPage]
    let initialIndex: Int

    init(pages: [ImagePreviewPage], initialIndex: Int = 0) {
        self.pages = pages
        self.initialIndex = initialIndex
    }

    init(url: URL, thumbnailURL: URL? = nil) {
        self.init(pages: [ImagePreviewPage(id: url.absoluteString, previewURL: url, thumbnailURL: thumbnailURL)])
    }
}

extension View {
    func imagePreview(_ selection: Binding<ImagePreviewSelection?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: selection) { ImagePreviewView(selection: $0) }
        #else
        sheet(item: selection) { ImagePreviewView(selection: $0).frame(minWidth: 640, minHeight: 420) }
        #endif
    }
}

/// 详情页头图可点开，标题、标签和播放控件仍由上层布局处理。
struct DetailHeroArtwork: View {
    let item: MediaItem
    let client: MediaServerClient?
    let style: LibraryPreferences.ArtworkStyle
    let posterWidth: Int
    let backdropWidth: Int
    @State private var selection: ImagePreviewSelection?

    var body: some View {
        let backdrop = style == .backdrop ? client?.imageURL(for: item, kind: .backdrop, maxWidth: backdropWidth) : nil
        let url = backdrop ?? client?.imageURL(for: item, kind: .primary, maxWidth: posterWidth)
        let kind: MediaItem.ImageKind = backdrop == nil ? .primary : .backdrop
        Group {
            if let url {
                Button {
                    let previewURL = client?.imageURL(for: item, kind: kind, maxWidth: 2560) ?? url
                    selection = ImagePreviewSelection(url: previewURL, thumbnailURL: url)
                } label: {
                    Color.clear
                        .overlay { RemoteArtwork(url: url) }
                        .clipped()
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind == .primary ? "查看海报" : "查看背景图")
            } else {
                RemoteArtwork(url: nil)
            }
        }
        .imagePreview($selection)
    }
}

private struct ImagePreviewView: View {
    let selection: ImagePreviewSelection
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int?
    @State private var zoomingPage: Int?
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var pullDistance: CGFloat = 0

    init(selection: ImagePreviewSelection) {
        self.selection = selection
        _page = State(initialValue: min(max(selection.initialIndex, 0), max(selection.pages.count - 1, 0)))
    }

    private var pages: [ImagePreviewPage] { selection.pages }
    private var currentPage: Int { page ?? 0 }
    private var canPullToDismiss: Bool { zoomingPage != currentPage }

    var body: some View {
        ZStack {
            Color.black.opacity(max(0.35, 1 - Double(pullDistance) / 450)).ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, image in
                        ZoomablePreviewPage(
                            previewURL: previewURL(for: image, index: index),
                            thumbnailURL: image.thumbnailURL,
                            isCurrent: index == currentPage,
                            onZoomActivity: { active in
                                if active, currentPage == index { zoomingPage = index }
                                if !active, zoomingPage == index { zoomingPage = nil }
                            },
                            onClose: { dismiss() }
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $page)
            .scrollTargetBehavior(.paging)
            .scrollDisabled(!canPullToDismiss)
            .velaHideHorizontalScrollIndicators()
            .offset(y: pullDistance)
            .simultaneousGesture(pullToDismiss, isEnabled: canPullToDismiss)
            .overlay(alignment: .topTrailing) {
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .padding(20)
                    .keyboardShortcut(.cancelAction)
            }
            .overlay(alignment: .bottom) {
                if pages.count > 1 {
                    HStack(spacing: 24) {
                        Button("上一张", systemImage: "chevron.left") { move(-1) }
                            .disabled(currentPage == 0)
                        Text("\(currentPage + 1) / \(pages.count)")
                            .monospacedDigit()
                            .accessibilityLabel("第 \(currentPage + 1) 张，共 \(pages.count) 张")
                        Button("下一张", systemImage: "chevron.right") { move(1) }
                            .disabled(currentPage == pages.count - 1)
                    }
                    .labelStyle(.iconOnly)
                    .padding(20)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(.bottom, 20)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .task(id: currentPage, priority: .utility) {
            await prefetchPreviews(around: currentPage)
        }
    }

    private func previewURL(for image: ImagePreviewPage, index: Int) -> URL? {
        if index == currentPage { return image.previewURL }
        guard abs(index - currentPage) == 1, ImagePipeline.shared.cachedImage(for: image.previewURL) != nil else { return nil }
        return image.previewURL
    }

    private func prefetchPreviews(around index: Int) async {
        guard pages.indices.contains(index), pages.count > 1 else { return }
        // 当前图优先；图片视图与预取共用正在进行的请求。
        _ = await ImagePipeline.shared.image(for: pages[index].previewURL)
        for neighbor in [index + 1, index - 1] where pages.indices.contains(neighbor) {
            guard !Task.isCancelled else { return }
            _ = await ImagePipeline.shared.image(for: pages[neighbor].previewURL, priority: .utility)
        }
    }

    private var pullToDismiss: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($pullDistance) { value, offset, _ in
                guard canPullToDismiss else { return }
                offset = downwardDistance(value.translation)
            }
            .onEnded { value in
                guard canPullToDismiss else { return }
                let distance = downwardDistance(value.translation)
                if distance >= 100 || (distance >= 30 && downwardDistance(value.predictedEndTranslation) >= 180) {
                    dismiss()
                }
            }
    }

    private func downwardDistance(_ translation: CGSize) -> CGFloat {
        translation.height > abs(translation.width) * 1.35 ? translation.height : 0
    }

    private func move(_ delta: Int) {
        zoomingPage = nil
        withAnimation { page = min(max(currentPage + delta, 0), pages.count - 1) }
    }
}

private struct ZoomablePreviewPage: View {
    let previewURL: URL?
    let thumbnailURL: URL?
    let isCurrent: Bool
    let onZoomActivity: (Bool) -> Void
    let onClose: () -> Void

    @State private var preview: CGImage?
    @State private var thumbnail: CGImage?
    @State private var previewFailed = false
    @State private var transform = Transform()
    @GestureState private var pinch: MagnifyGesture.Value? = nil
    @GestureState private var drag: CGSize = .zero

    private var image: CGImage? {
        preview ?? previewURL.flatMap { ImagePipeline.shared.cachedImage(for: $0) }
            ?? thumbnail ?? thumbnailURL.flatMap { ImagePipeline.shared.cachedImage(for: $0) }
    }

    private var isZooming: Bool { isCurrent && (pinch != nil || transform.scale > 1) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let image = image
            let fitted = image.map { fittedSize(for: $0, in: size) } ?? .zero
            let current = displayedTransform(in: size, fitted: fitted)
            Color.clear
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .scaleEffect(current.scale)
                            .offset(current.offset)
                    } else if previewFailed {
                        Label("无法加载图片", systemImage: "photo")
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .clipped()
                .contentShape(.rect)
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { tap in
                        guard image != nil else { return }
                        withAnimation(.snappy) {
                            transform = transform.scale > 1
                                ? Transform()
                                : transform.scaled(to: 2.5, around: tap.location, in: size).clamped(to: size, fitted: fitted)
                        }
                    }
                    .exclusively(before: TapGesture().onEnded { onClose() }),
                    isEnabled: isCurrent
                )
                .simultaneousGesture(magnify(in: size, fitted: fitted), isEnabled: isCurrent && image != nil)
                .simultaneousGesture(pan(in: size, fitted: fitted), isEnabled: isCurrent && transform.scale > 1 && pinch == nil)
                .onChange(of: fitted) { transform = transform.clamped(to: size, fitted: fitted) }
                .onChange(of: size) { transform = transform.clamped(to: size, fitted: fitted) }
        }
        .onChange(of: isCurrent) { if !isCurrent { transform = Transform() } }
        .onChange(of: isZooming) { onZoomActivity(isZooming) }
        .task(id: previewURL) {
            preview = nil
            previewFailed = false
            guard let previewURL else { return }
            let result = await ImagePipeline.shared.image(for: previewURL)
            guard !Task.isCancelled else { return }
            preview = result
            previewFailed = result == nil
        }
        .task(id: thumbnailURL) {
            guard let thumbnailURL, thumbnailURL != previewURL else { return }
            let result = await ImagePipeline.shared.image(for: thumbnailURL)
            if !Task.isCancelled { thumbnail = result }
        }
    }

    private func fittedSize(for image: CGImage, in size: CGSize) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let ratio = min(size.width / width, size.height / height)
        return CGSize(width: width * ratio, height: height * ratio)
    }

    private func displayedTransform(in size: CGSize, fitted: CGSize) -> Transform {
        let next = if let pinch {
            transform.scaled(to: transform.scale * pinch.magnification, around: pinch.startLocation, in: size)
        } else {
            transform.translated(by: drag)
        }
        return next.clamped(to: size, fitted: fitted)
    }

    private func magnify(in size: CGSize, fitted: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                transform = transform.scaled(to: transform.scale * value.magnification, around: value.startLocation, in: size)
                    .clamped(to: size, fitted: fitted)
            }
    }

    private func pan(in size: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                guard pinch == nil else { return }
                transform = transform.translated(by: value.translation).clamped(to: size, fitted: fitted)
            }
    }

    private struct Transform {
        var scale: CGFloat = 1
        var offset: CGSize = .zero

        func scaled(to proposedScale: CGFloat, around point: CGPoint, in size: CGSize) -> Self {
            let nextScale = min(max(proposedScale, 1), 5)
            let ratio = nextScale / scale
            // 以捏合或双击的位置为支点，直到图片边缘触及视口。
            return Self(scale: nextScale, offset: CGSize(
                width: ratio * offset.width + (1 - ratio) * (point.x - size.width / 2),
                height: ratio * offset.height + (1 - ratio) * (point.y - size.height / 2)
            ))
        }

        func translated(by translation: CGSize) -> Self {
            Self(scale: scale, offset: CGSize(width: offset.width + translation.width, height: offset.height + translation.height))
        }

        func clamped(to size: CGSize, fitted: CGSize) -> Self {
            let maxX = max((fitted.width * scale - size.width) / 2, 0)
            let maxY = max((fitted.height * scale - size.height) / 2, 0)
            return Self(scale: scale, offset: CGSize(
                width: min(max(offset.width, -maxX), maxX),
                height: min(max(offset.height, -maxY), maxY)
            ))
        }
    }
}
