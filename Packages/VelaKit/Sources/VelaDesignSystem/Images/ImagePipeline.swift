import CryptoKit
import Foundation
import ImageIO

/// 远程图片加载：内存缓存 → 磁盘缓存 → 网络，三级查找；同一地址的并发请求合并为一次下载。
///
/// - 缓存键是完整 URL。服务器图片地址带 tag（内容变化时 tag 变化），且不含访问 token，可以长期缓存。
/// - 解码在后台完成（`kCGImageSourceShouldCacheImmediately`），滚动时主线程只做显示。
/// - 磁盘缓存上限 `diskLimit`，超出时按最后访问时间淘汰；系统也可能在存储紧张时清理 Caches 目录。
public final class ImagePipeline: Sendable {
    public static let shared = ImagePipeline()

    /// 磁盘缓存上限（字节）。
    public static let diskLimit: Int64 = 500 * 1024 * 1024

    private let memory = MemoryCache()
    private let loader: Loader
    let directory: URL

    init(directory: URL = URL.cachesDirectory.appending(path: "Vela/Images", directoryHint: .isDirectory)) {
        self.directory = directory
        // 不用 URLCache：磁盘缓存由本类统一管理，避免同一张图存两份。
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        self.loader = Loader(session: URLSession(configuration: configuration), directory: directory)
    }

    /// 内存中已解码的图片；用于视图首次渲染时直接显示，避免滚动复用时闪烁。
    public func cachedImage(for url: URL) -> CGImage? {
        memory.image(for: url)
    }

    /// 加载图片；失败（404、网络错误、无法解码）返回 nil，由调用方显示占位。
    public func image(for url: URL) async -> CGImage? {
        if let image = memory.image(for: url) { return image }
        guard let image = await loader.load(url) else { return nil }
        memory.store(image, for: url)
        return image
    }

    /// 低优先级预取（进入内存缓存）；网格加载下一页后调用，滚动到时图片通常已就绪。
    public func prefetch(_ urls: [URL]) {
        let pending = urls.filter { memory.image(for: $0) == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            for url in pending.prefix(Self.prefetchLimit) {
                _ = await self.image(for: url)
            }
        }
    }

    /// 单次预取上限，避免一次排入过多下载挤占前台请求。
    private static let prefetchLimit = 40

    /// 磁盘缓存占用（字节）。
    public func diskUsage() async -> Int64 {
        await loader.diskUsage()
    }

    public func removeAll() async {
        memory.removeAll()
        await loader.removeAll()
    }

    // MARK: - 内存缓存

    /// `NSCache` 本身线程安全；按像素数估算开销，上限约 150 MB。
    private final class MemoryCache: @unchecked Sendable {
        private let cache: NSCache<NSURL, CGImage> = {
            let cache = NSCache<NSURL, CGImage>()
            cache.totalCostLimit = 150 * 1024 * 1024
            return cache
        }()

        func image(for url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }

        func store(_ image: CGImage, for url: URL) {
            cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }

        func removeAll() { cache.removeAllObjects() }
    }

    // MARK: - 磁盘与网络

    private actor Loader {
        private let session: URLSession
        private let directory: URL
        private var inFlight: [URL: Task<CGImage?, Never>] = [:]
        private var writesSinceTrim = 0

        /// 每写入这么多张图检查一次磁盘占用。
        private static let trimInterval = 200

        init(session: URLSession, directory: URL) {
            self.session = session
            self.directory = directory
        }

        func load(_ url: URL) async -> CGImage? {
            if let task = inFlight[url] { return await task.value }
            let file = fileURL(for: url)
            let session = session
            let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
                if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
                    Self.touch(file)
                    return image
                }
                guard let (data, response) = try? await session.data(from: url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let image = Self.decode(data) else { return nil }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                return image
            }
            inFlight[url] = task
            let image = await task.value
            inFlight[url] = nil
            writesSinceTrim += 1
            if writesSinceTrim >= Self.trimInterval {
                writesSinceTrim = 0
                trim()
            }
            return image
        }

        func diskUsage() -> Int64 {
            files().reduce(0) { $0 + $1.size }
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// 超出上限时按修改时间（读取时会刷新）从旧到新删除，直到降到上限的 80%。
        private func trim() {
            var entries = files()
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > ImagePipeline.diskLimit else { return }
            entries.sort { $0.date < $1.date }
            let target = ImagePipeline.diskLimit * 8 / 10
            for entry in entries where total > target {
                try? FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            }
        }

        private func files() -> [(url: URL, size: Int64, date: Date)] {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
            return urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
        }

        private func fileURL(for url: URL) -> URL {
            let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            let name = digest.map { String(format: "%02x", $0) }.joined()
            return directory.appending(path: name)
        }

        /// 读取命中时刷新修改时间，供淘汰判断；一天内只刷新一次，减少磁盘写入。
        private static func touch(_ file: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            if let date = attributes?[.modificationDate] as? Date, Date.now.timeIntervalSince(date) < 86_400 { return }
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        }

        /// 解码像素上限（长边）。服务器图片已按请求宽度缩放，这里只兜底异常大图（例如未带 maxWidth 的原图）。
        private static let maxPixelSize = 2048

        private static func decode(_ data: Data) -> CGImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            // 缩略图接口在解码时直接降采样，大图不会先完整解码再缩小。
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
    }
}
