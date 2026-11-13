import SwiftUI
import VelaDesignSystem
import VelaNetwork

/// Vela 相册：固定 268pt、16:9 裁切缩略图；大小图使用独立缓存键。
struct StillsShelf: View {
    let images: [DetailStill]
    @Environment(\.velaLayout) private var layout
    @State private var selection: ImagePreviewSelection?
    @State private var lastVisibleIndex: Int?

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
                            Button {
                                selection = ImagePreviewSelection(pages: images.map {
                                    ImagePreviewPage(id: $0.id, previewURL: $0.previewURL, thumbnailURL: $0.thumbnailURL)
                                }, initialIndex: index)
                            } label: {
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
            .imagePreview($selection)
        }
    }
}
