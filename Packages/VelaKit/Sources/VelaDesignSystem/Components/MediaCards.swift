import SwiftUI

/// 远程图片 + 占位。图片地址带服务器 tag，可由 URLCache 长期缓存。
public struct RemoteArtwork: View {
    let url: URL?
    let placeholderSymbol: String

    public init(url: URL?, placeholderSymbol: String = "film") {
        self.url = url
        self.placeholderSymbol = placeholderSymbol
    }

    public var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: placeholderSymbol)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// 竖版海报卡（2:3）。
public struct PosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let progress: Double?
    let width: CGFloat

    public init(title: String, subtitle: String?, imageURL: URL?, progress: Double? = nil, width: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.xs) {
            RemoteArtwork(url: imageURL)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) { ProgressStrip(progress: progress) }
                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 横版卡（16:9），用于继续观看。
public struct LandscapeCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let progress: Double?
    let width: CGFloat

    public init(title: String, subtitle: String?, imageURL: URL?, progress: Double? = nil, width: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.xs) {
            RemoteArtwork(url: imageURL, placeholderSymbol: "play.rectangle")
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) { ProgressStrip(progress: progress) }
                .clipShape(.rect(cornerRadius: VelaTheme.Radius.card))
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
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
                    Rectangle().fill(VelaTheme.accent).frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 4)
            .accessibilityLabel(Text("已观看 \(Int(progress * 100))%"))
        }
    }
}

/// 横向滚动的分区。
public struct MediaShelf<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    let card: (Item) -> Card

    public init(_ title: String, items: [Item], @ViewBuilder card: @escaping (Item) -> Card) {
        self.title = title
        self.items = items
        self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: VelaTheme.Spacing.s) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, VelaTheme.Spacing.l)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: VelaTheme.Spacing.m) {
                    ForEach(items) { item in card(item) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, VelaTheme.Spacing.l)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}
