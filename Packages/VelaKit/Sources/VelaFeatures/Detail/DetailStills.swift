import SwiftUI
import VelaDesignSystem
import VelaNetwork

/// Vela 相册：固定 268pt、16:9 裁切缩略图；大小图使用独立缓存键。
struct StillsShelf: View {
    let images: [DetailStill]
    @Environment(\.velaLayout) private var layout
    @State private var selection: Selection?
    @State private var lastVisibleIndex: Int?

    private struct Selection: Identifiable {
        let id = UUID()
        let index: Int
        let images: [DetailStill]
    }

    private var upcomingThumbnails: [URL] {
        guard let lastVisibleIndex else { return [] }
        return images.dropFirst(lastVisibleIndex + 1).prefix(2).map(\.thumbnailURL)
    }

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: VelaTheme.Spacing.m) {
                Text("剧照").font(.title2.weight(.bold)).velaPageMargin()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                            Button { selection = Selection(index: index, images: images) } label: {
                                // 先确定容器，再让图片填充；原图比例不能改变布局尺寸。
                                Color.clear
                                    .frame(width: 268, height: 268 * 9 / 16)
                                    .overlay {
                                        RemoteArtwork(url: image.thumbnailURL, placeholderSymbol: "photo")
                                    }
                                    .clipShape(.rect(cornerRadius: 12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12))
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看剧照 \(index + 1)，共 \(images.count) 张")
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, layout.pageMargin, for: .scrollContent)
                .velaHideHorizontalScrollIndicators()
                .scrollTargetBehavior(.viewAligned)
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { ids in
                    let visibleIDs = Set(ids)
                    lastVisibleIndex = images.lastIndex { visibleIDs.contains($0.id) }
                }
                .velaHorizontalPaging()
                .task(id: upcomingThumbnails, priority: .utility) { [urls = upcomingThumbnails] in
                    for url in urls {
                        guard !Task.isCancelled else { return }
                        _ = await ImagePipeline.shared.image(for: url, priority: .utility)
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $selection) { selected in
                StillPreview(images: selected.images, initialIndex: selected.index)
            }
            #else
            .sheet(item: $selection) { selected in
                StillPreview(images: selected.images, initialIndex: selected.index)
                    .frame(minWidth: 640, minHeight: 420)
            }
            #endif
        }
    }
}

/// 大图保持原比例，横滑翻页，下拉或点按关闭。
private struct StillPreview: View {
    let images: [DetailStill]
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int?
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var pullDistance: CGFloat = 0

    init(images: [DetailStill], initialIndex: Int) {
        self.images = images
        _page = State(initialValue: min(max(initialIndex, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        let currentPage = page ?? 0
        ZStack {
            Color.black.opacity(max(0.35, 1 - Double(pullDistance) / 450)).ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Color.clear
                            .containerRelativeFrame([.horizontal, .vertical])
                            .overlay {
                                CachedImage(url: previewURL(for: image, index: index, currentPage: currentPage), contentMode: .fit) {
                                    CachedImage(url: image.thumbnailURL, contentMode: .fit) {
                                        ProgressView().tint(.white)
                                    }
                                }
                            }
                            .clipped()
                            .contentShape(.rect)
                            .onTapGesture { dismiss() }
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $page)
            .scrollTargetBehavior(.paging)
            .velaHideHorizontalScrollIndicators()
            .offset(y: pullDistance)
            .simultaneousGesture(pullToDismiss)
            .overlay(alignment: .topTrailing) {
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .padding(20)
                    .accessibilityLabel("关闭剧照")
                    .keyboardShortcut(.cancelAction)
            }
            .overlay(alignment: .bottom) {
                if images.count > 1 {
                    HStack(spacing: 24) {
                        Button("上一张", systemImage: "chevron.left") { move(-1) }
                            .disabled(currentPage == 0)
                        Text("\(currentPage + 1) / \(images.count)")
                            .monospacedDigit()
                            .accessibilityLabel("第 \(currentPage + 1) 张，共 \(images.count) 张")
                        Button("下一张", systemImage: "chevron.right") { move(1) }
                            .disabled(currentPage == images.count - 1)
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

    private func previewURL(for image: DetailStill, index: Int, currentPage: Int) -> URL? {
        if index == currentPage { return image.previewURL }
        // 滑动时允许相邻页直接显示已预取的大图，远处的页不主动拉取大图。
        guard abs(index - currentPage) == 1, ImagePipeline.shared.cachedImage(for: image.previewURL) != nil else { return nil }
        return image.previewURL
    }

    private func prefetchPreviews(around index: Int) async {
        guard images.indices.contains(index) else { return }
        // 当前图优先；与视图的加载合并，完成后再按顺序预取相邻页。
        _ = await ImagePipeline.shared.image(for: images[index].previewURL)
        for neighbor in [index + 1, index - 1] where images.indices.contains(neighbor) {
            guard !Task.isCancelled else { return }
            _ = await ImagePipeline.shared.image(for: images[neighbor].previewURL, priority: .utility)
        }
    }

    private var pullToDismiss: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($pullDistance) { value, offset, _ in
                offset = downwardDistance(value.translation)
            }
            .onEnded { value in
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
        withAnimation { page = min(max((page ?? 0) + delta, 0), images.count - 1) }
    }
}
