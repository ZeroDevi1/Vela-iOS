import SwiftUI
import VelaDesignSystem
import VelaNetwork

/// Vela 相册：固定 268pt、16:9 裁切缩略图；大小图使用独立缓存键。
struct StillsShelf: View {
    let images: [DetailStill]
    @Environment(\.velaLayout) private var layout
    @State private var selection: Selection?

    private struct Selection: Identifiable {
        let id = UUID()
        let index: Int
        let images: [DetailStill]
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
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看剧照 \(index + 1)，共 \(images.count) 张")
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, layout.pageMargin, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .velaHorizontalPaging()
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

/// 与参考端一致：按原比例适配、左右翻页、点按关闭；参考端没有缩放手势。
private struct StillPreview: View {
    let images: [DetailStill]
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int?

    init(images: [DetailStill], initialIndex: Int) {
        self.images = images
        _page = State(initialValue: min(max(initialIndex, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Color.clear
                            .containerRelativeFrame([.horizontal, .vertical])
                            .overlay {
                                CachedImage(url: index == page ? image.previewURL : nil, contentMode: .fit) {
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
            .scrollIndicators(.hidden)
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
                            .disabled((page ?? 0) == 0)
                        Text("\((page ?? 0) + 1) / \(images.count)")
                            .monospacedDigit()
                            .accessibilityLabel("第 \((page ?? 0) + 1) 张，共 \(images.count) 张")
                        Button("下一张", systemImage: "chevron.right") { move(1) }
                            .disabled((page ?? 0) == images.count - 1)
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
    }

    private func move(_ delta: Int) {
        withAnimation { page = min(max((page ?? 0) + delta, 0), images.count - 1) }
    }
}
