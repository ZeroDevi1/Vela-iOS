import SwiftUI

/// 经 `ImagePipeline` 缓存的远程图片；加载中或失败时显示 `placeholder`。
///
/// 内存命中时首帧直接显示（列表滚动复用不闪烁）；否则先显示占位，加载完成后淡入。
public struct CachedImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholder: Placeholder

    @State private var loaded: (url: URL, image: CGImage)?

    public init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    public var body: some View {
        ZStack {
            if let image = currentImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url, currentImage == nil else { return }
            if let image = await ImagePipeline.shared.image(for: url), !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (url, image) }
            }
        }
    }

    /// 只显示与当前 URL 对应的图片：视图被复用到别的条目时不残留旧图。
    private var currentImage: CGImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ImagePipeline.shared.cachedImage(for: url)
    }
}

/// 海报 / 剧照：缓存图片 + 灰底图标占位。
public struct RemoteArtwork: View {
    let url: URL?
    let placeholderSymbol: String

    /// - Parameter placeholderSymbol: 占位图标；空字符串只显示灰底。
    public init(url: URL?, placeholderSymbol: String = "film") {
        self.url = url
        self.placeholderSymbol = placeholderSymbol
    }

    public var body: some View {
        CachedImage(url: url) {
            ZStack {
                Rectangle().fill(.quaternary)
                if !placeholderSymbol.isEmpty {
                    Image(systemName: placeholderSymbol)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// 海报角标：右上角未看集数或已看勾，右下角评分。
public struct PosterBadges: Equatable, Sendable {
    public var unplayedCount: Int?
    public var isPlayed: Bool
    public var rating: Double?
    /// 大于 1 时左上角显示「N 版本」。
    public var versionCount: Int

    public init(unplayedCount: Int? = nil, isPlayed: Bool = false, rating: Double? = nil, versionCount: Int = 1) {
        self.unplayedCount = unplayedCount
        self.isPlayed = isPlayed
        self.rating = rating
        self.versionCount = versionCount
    }
}

/// 海报卡的显示偏好（「媒体库配置 → 海报偏好」），由应用根视图通过环境注入。
public struct PosterDisplayOptions: Equatable, Sendable {
    public var titleAlignment: HorizontalAlignment = .center
    public var showRating = true
    public var showPlayedMark = true
    public var showUnplayedCount = true

    public init(titleAlignment: HorizontalAlignment = .center, showRating: Bool = true, showPlayedMark: Bool = true, showUnplayedCount: Bool = true) {
        self.titleAlignment = titleAlignment
        self.showRating = showRating
        self.showPlayedMark = showPlayedMark
        self.showUnplayedCount = showUnplayedCount
    }
}

extension EnvironmentValues {
    @Entry public var posterDisplay = PosterDisplayOptions()
}

/// 竖版海报卡（2:3），标题对齐方式与角标按 `posterDisplay` 环境值显示。
public struct PosterCard: View {
    @Environment(\.posterDisplay) private var display
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let progress: Double?
    let width: CGFloat
    let badges: PosterBadges

    public init(title: String, subtitle: String?, imageURL: URL?, progress: Double? = nil, width: CGFloat, badges: PosterBadges = .init()) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
        self.width = width
        self.badges = badges
    }

    public var body: some View {
        // 标题、副标题显示在海报下方，默认居中（与 Android 版一致），可设置为左对齐。
        VStack(alignment: display.titleAlignment, spacing: 2) {
            RemoteArtwork(url: imageURL)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) { ProgressStrip(progress: progress) }
                .overlay(alignment: .topTrailing) { topBadge }
                .overlay(alignment: .bottomTrailing) { ratingBadge }
                .overlay(alignment: .topLeading) { versionBadge }
                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                .velaCardHover()
                .padding(.bottom, VelaTheme.Spacing.xs)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(display.titleAlignment == .leading ? .leading : .center)
        .frame(width: width, alignment: display.titleAlignment == .leading ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var topBadge: some View {
        if display.showUnplayedCount, let count = badges.unplayedCount, count > 0 {
            // 未看集数：深色半透明圆角标，超过 99 显示「99+」。
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 22)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(6)
                .accessibilityLabel("\(count) 集未看")
        } else if display.showPlayedMark, badges.isPlayed {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, VelaTheme.accentDeep)
                .padding(6)
                .accessibilityLabel("已看")
        }
    }

    @ViewBuilder
    private var versionBadge: some View {
        if badges.versionCount > 1 {
            Text("\(badges.versionCount) 版本")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(6)
        }
    }

    @ViewBuilder
    private var ratingBadge: some View {
        if display.showRating, let rating = badges.rating, rating > 0 {
            Text(rating.formatted(.number.precision(.fractionLength(1))))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: .capsule)
                .padding(6)
                .accessibilityLabel("评分 \(rating.formatted(.number.precision(.fractionLength(1))))")
        }
    }
}

/// 横版卡（16:9），用于媒体库入口与继续观看；标题居中（与 Android 版一致）。
public struct LandscapeCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let progress: Double?
    let width: CGFloat
    /// 画面右上角的角标，例如「剩余 15 分钟」。
    let caption: String?

    public init(title: String, subtitle: String?, imageURL: URL?, progress: Double? = nil, width: CGFloat, caption: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
        self.width = width
        self.caption = caption
    }

    public var body: some View {
        VStack(spacing: 2) {
            RemoteArtwork(url: imageURL, placeholderSymbol: "play.rectangle")
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .topTrailing) {
                    if let caption {
                        Text(caption)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: .capsule)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) { ProgressStrip(progress: progress) }
                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
                .velaCardHover()
                .padding(.bottom, VelaTheme.Spacing.xs)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: width)
        .accessibilityElement(children: .combine)
    }
}

/// 卡片底部的观看进度条。没有进度时不占位。
struct ProgressStrip: View {
    let progress: Double?

    var body: some View {
        if let progress, progress > 0 {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.45))
                    // 与 Android 版一致使用红色进度，在任意海报色调上都醒目。
                    Rectangle().fill(.red).frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 4)
            .accessibilityLabel(Text("已观看 \(Int(progress * 100))%"))
        }
    }
}

/// 横向滚动的分区。标题右侧可放附件（例如「75 ›」查看全部）。
public struct MediaShelf<Item: Identifiable, Card: View, Accessory: View>: View {
    let title: String
    let items: [Item]
    let card: (Item) -> Card
    let accessory: Accessory
    @Environment(\.velaLayout) private var layout

    public init(
        _ title: String,
        items: [Item],
        @ViewBuilder card: @escaping (Item) -> Card,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.items = items
        self.card = card
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: VelaTheme.Spacing.s)
                accessory
            }
            .padding(.horizontal, layout.pageMargin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                    ForEach(items) { item in card(item) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, layout.pageMargin)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .velaHorizontalPaging()
        }
    }
}

extension MediaShelf where Accessory == EmptyView {
    public init(_ title: String, items: [Item], @ViewBuilder card: @escaping (Item) -> Card) {
        self.init(title, items: items, card: card) { EmptyView() }
    }
}

/// 分区标题右侧的「数量 ›」，用作查看全部的入口标签。
public struct ShelfCountLabel: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 2) {
            Text(count.formatted())
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityLabel("查看全部 \(count) 项")
    }
}

/// 分区标题右侧的「→」，查看全部入口（与 Android 版「最近添加」分区一致）。
public struct ShelfViewAllArrow: View {
    public init() {}

    public var body: some View {
        Image(systemName: "arrow.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
            .accessibilityLabel("查看全部")
    }
}
