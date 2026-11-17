import CoreGraphics
import Foundation
import ImageIO
import VelaCore
import VelaNetwork
import VelaPlayer

/// 索引和图片只供当前媒体版本使用。Jellyfin 同一张图板上的多帧共用一次下载。
actor ServerScrubPreviews {
    private enum Index: Sendable {
        case jellyfin(JellyfinTrickplayLayout)
        case emby(itemID: String, thumbnails: [EmbySeekThumbnail])
    }

    private let client: MediaServerClient
    private let itemID: String
    private let source: MediaSourceInfo
    private var indexTask: Task<Index?, Never>?
    private var tile: (number: Int, image: CGImage)?
    private var tileTransfer: (number: Int, id: UUID, task: Task<CGImage?, Never>)?

    init(client: MediaServerClient, itemID: String, source: MediaSourceInfo) {
        self.client = client
        self.itemID = itemID
        self.source = source
    }

    deinit {
        indexTask?.cancel()
        tileTransfer?.task.cancel()
    }

    func frame(at time: TimeInterval) async -> ScrubPreviewFrameSample? {
        let task = indexTask ?? Task { [client, itemID, source] in
            try? await Self.loadIndex(client: client, itemID: itemID, source: source)
        }
        indexTask = task
        guard let index = await task.value, !Task.isCancelled else { return nil }
        switch index {
        case .jellyfin(let layout):
            let interval = Double(layout.interval) / 1000
            let sample = Int(min((time / interval).rounded(), Double(layout.thumbnailCount - 1)))
            let frameTime = Double(sample) * interval
            guard abs(frameTime - time) <= 5 else { return nil }
            let (number, cell) = sample.quotientAndRemainder(dividingBy: layout.columns * layout.rows)
            guard let tile = await loadTile(number: number, layout: layout), !Task.isCancelled else { return nil }
            let rect = CGRect(x: (cell % layout.columns) * layout.width, y: (cell / layout.columns) * layout.height,
                              width: layout.width, height: layout.height)
            guard rect.maxX <= CGFloat(tile.width), rect.maxY <= CGFloat(tile.height),
                  let cellImage = tile.cropping(to: rect),
                  let bitmap = CGContext(data: nil, width: layout.width, height: layout.height, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            // 拷出小图，避免缓存一格时仍持有整张图板的解码内存。
            bitmap.draw(cellImage, in: CGRect(origin: .zero, size: rect.size))
            return bitmap.makeImage().map { ScrubPreviewFrameSample(image: $0, time: frameTime) }
        case .emby(let itemID, let thumbnails):
            guard let entry = thumbnails.min(by: {
                abs(Ticks.seconds($0.positionTicks) - time) < abs(Ticks.seconds($1.positionTicks) - time)
            }) else { return nil }
            let frameTime = Ticks.seconds(entry.positionTicks)
            guard abs(frameTime - time) <= 5,
                  let data = try? await client.embySeekThumbnail(itemID: itemID, mediaSourceID: source.id, thumbnail: entry),
                  !Task.isCancelled, let image = Self.decode(data, maxPixels: 1_000_000) else { return nil }
            return ScrubPreviewFrameSample(image: image, time: frameTime)
        }
    }

    private static func loadIndex(client: MediaServerClient, itemID: String, source: MediaSourceInfo) async throws -> Index? {
        switch client.kind {
        case .jellyfin:
            let layouts = try await client.trickplayLayouts(itemID: itemID, mediaSourceID: source.id)
            return layouts.filter { layout in
                (1...480).contains(layout.width) && (1...480).contains(layout.height)
                    && (1...20).contains(layout.columns) && (1...20).contains(layout.rows)
                    && (1...1_000_000).contains(layout.thumbnailCount) && layout.interval > 0
                    && layout.width * layout.height * layout.columns * layout.rows <= 8_000_000
            }.max(by: { $0.width < $1.width }).map(Index.jellyfin)
        case .emby:
            let thumbnailItemID: String
            if let sourceItemID = source.itemID, !sourceItemID.isEmpty, sourceItemID != "0" {
                thumbnailItemID = sourceItemID
            } else if source.id.hasPrefix("mediasource_"), let version = Int64(source.id.dropFirst("mediasource_".count)), version > 0 {
                thumbnailItemID = String(version)
            } else {
                // 旧版的媒体源 ID 未必等于条目 ID。只在确认主版本时使用该条目的 BIF 索引。
                let details = try await client.itemDetails(id: itemID)
                guard details.mediaSources.first?.id == source.id else { return nil }
                thumbnailItemID = itemID
            }
            let thumbnails = try await client.embySeekThumbnails(itemID: thumbnailItemID)
            return thumbnails.isEmpty ? nil : .emby(itemID: thumbnailItemID, thumbnails: thumbnails)
        case .navidrome:
            return nil
        }
    }

    private func loadTile(number: Int, layout: JellyfinTrickplayLayout) async -> CGImage? {
        if let tile, tile.number == number { return tile.image }

        if tileTransfer?.number != number {
            tileTransfer?.task.cancel()
            let task = Task { [client, itemID, source] in
                guard let data = try? await client.trickplayTile(itemID: itemID, mediaSourceID: source.id,
                                                               width: layout.width, index: number),
                      !Task.isCancelled else { return nil as CGImage? }
                return Self.decode(data, maxPixels: 8_000_000)
            }
            tileTransfer = (number, UUID(), task)
        }
        guard let transfer = tileTransfer else { return nil }
        let image = await transfer.task.value
        if transfer.id == tileTransfer?.id {
            tileTransfer = nil
            if let image { tile = (number, image) }
        }
        return image
    }

    private static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              height <= maxPixels / width else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
