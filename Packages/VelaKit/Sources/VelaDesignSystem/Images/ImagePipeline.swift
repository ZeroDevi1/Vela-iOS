import CryptoKit
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// 远程图片加载：内存缓存 → 磁盘缓存 → 网络，三级查找；同一地址的并发请求合并为一次下载。
///
/// - 缓存键是完整 URL。服务器图片地址带 tag（内容变化时 tag 变化），且不含访问 token，可以长期缓存。
/// - 解码在后台完成（`kCGImageSourceShouldCacheImmediately`），滚动时主线程只做显示。
/// - 磁盘缓存上限 `diskLimit`（设置中可调），累计大小在写入时维护，超出才按最后访问时间淘汰；
///   系统也可能在存储紧张时清理 Caches 目录。
/// - 服务器明确表示没有这张图（4xx）时短期记住，避免无图条目每次滚动都重新请求。
public final class ImagePipeline: Sendable {
    public static let shared = ImagePipeline()

    /// 可选的磁盘缓存上限（字节）。
    public static let diskLimitOptions: [Int64] = [256, 512, 1024, 2048].map { $0 * 1024 * 1024 }
    private static let diskLimitKey = "imageCache.diskLimit"

    /// 磁盘缓存上限（字节），默认 512 MB；修改后下次写入时按新上限淘汰。
    public static var diskLimit: Int64 {
        get {
            let stored = Int64(UserDefaults.standard.integer(forKey: diskLimitKey))
            return stored > 0 ? stored : 512 * 1024 * 1024
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: diskLimitKey) }
    }

    private let memory: MemoryCache
    private let loader: Loader
    let directory: URL

    init(directory: URL = URL.cachesDirectory.appending(path: "Vela/Images", directoryHint: .isDirectory)) {
        self.directory = directory
        let memory = MemoryCache()
        self.memory = memory
        // 不用 URLCache：磁盘缓存由本类统一管理，避免同一张图存两份。
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        self.loader = Loader(session: URLSession(configuration: configuration), directory: directory, memory: memory)
        #if canImport(UIKit)
        // NSCache 在内存压力下也会自行淘汰，但收到警告时立即清空能更快释放已解码的位图。
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            memory.removeAll()
        }
        #endif
    }

    /// 启动后在后台调用一次：统计磁盘占用并按上限淘汰（例如上次运行后调小了上限）。
    public func trimDiskCache() async {
        await loader.trimIfNeeded()
    }

    /// 内存中已解码的图片；用于视图首次渲染时直接显示，避免滚动复用时闪烁。
    public func cachedImage(for url: URL) -> CGImage? {
        memory.image(for: url)
    }

    /// 加载图片；失败（404、网络错误、无法解码）返回 nil，由调用方显示占位。
    public func image(for url: URL, priority: TaskPriority = .userInitiated) async -> CGImage? {
        if let image = memory.image(for: url) { return image }
        return await loader.load(url, priority: priority)
    }

    /// 需要鉴权的图片使用不含凭据的稳定标识去重，下载器负责生成实际请求。
    public func image(key: URL, memoryOnly: Bool, fetch: @escaping @Sendable () async throws -> Data) async -> CGImage? {
        await loader.load(key, priority: .userInitiated, memoryOnly: memoryOnly, download: fetch)
    }

    /// 低优先级预取（进入内存缓存）；网格加载下一页后调用，滚动到时图片通常已就绪。
    public func prefetch(_ urls: [URL]) {
        let pending = urls.filter { memory.image(for: $0) == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            for url in pending.prefix(Self.prefetchLimit) {
                _ = await self.image(for: url, priority: .utility)
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

    /// `NSCache` 本身线程安全；按位图字节数计开销，上限为设备内存的 1/32，限定在 64～256 MB
    /// （8 GB 内存的 iPhone 16 Pro 为 256 MB，4 GB 设备为 128 MB）。
    private final class MemoryCache: @unchecked Sendable {
        private let cache: NSCache<NSURL, CGImage> = {
            let cache = NSCache<NSURL, CGImage>()
            let budget = Int64(ProcessInfo.processInfo.physicalMemory / 32)
            cache.totalCostLimit = Int(min(max(budget, 64 * 1024 * 1024), 256 * 1024 * 1024))
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
        private let memory: MemoryCache
        private var inFlight: [URL: Task<Fetch, Never>] = [:]
        /// 磁盘缓存累计大小；首次需要时扫描一次目录，之后随写入 / 淘汰维护，不再每次枚举。
        private var diskSize: Int64?
        /// 服务器明确没有该图（4xx）或数据无法解码的地址 → 记录时间。网络错误不记录，恢复后可立即重试。
        private var failures: [URL: Date] = [:]

        /// 负缓存有效期（秒）：条目补图后最多等这么久就会重新请求。
        private static let failureTTL: TimeInterval = 600

        private enum Fetch: Sendable {
            case image(CGImage, writtenBytes: Int64)
            /// 服务器没有该图或无法解码，可短期记住。
            case missing
            /// 网络错误等暂时性失败。
            case failed
        }

        init(session: URLSession, directory: URL, memory: MemoryCache) {
            self.session = session
            self.directory = directory
            self.memory = memory
        }

        func load(_ url: URL, priority: TaskPriority, memoryOnly: Bool = false,
                  download: (@Sendable () async throws -> Data)? = nil) async -> CGImage? {
            if let image = memory.image(for: url) { return image }
            if let failedAt = failures[url] {
                if Date.now.timeIntervalSince(failedAt) < Self.failureTTL { return nil }
                failures[url] = nil
            }
            let fetch: Fetch
            if let task = inFlight[url] {
                fetch = await task.value
            } else {
                let task = makeFetch(url, priority: priority, memoryOnly: memoryOnly, download: download)
                inFlight[url] = task
                fetch = await task.value
                // 先填内存再清除进行中的请求，预取和界面同时查找时不会重复解码。
                if case .image(let image, let written) = fetch {
                    memory.store(image, for: url)
                    if written > 0 { didWrite(written) }
                }
                inFlight[url] = nil
                if case .missing = fetch { failures[url] = .now }
            }
            if case .image(let image, _) = fetch { return image }
            return nil
        }

        private func makeFetch(_ url: URL, priority: TaskPriority, memoryOnly: Bool,
                               download: (@Sendable () async throws -> Data)?) -> Task<Fetch, Never> {
            let file = fileURL(for: url)
            let session = session
            return Task.detached(priority: priority) { () -> Fetch in
                if !memoryOnly, let data = try? Data(contentsOf: file, options: .mappedIfSafe), let image = Self.decode(data) {
                    Self.touch(file)
                    return .image(image, writtenBytes: 0)
                }
                let data: Data
                if let download {
                    guard let bytes = try? await download() else { return .failed }
                    data = bytes
                } else {
                    guard let (bytes, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse else { return .failed }
                    guard (200..<300).contains(http.statusCode) else {
                        return (400..<500).contains(http.statusCode) ? .missing : .failed
                    }
                    data = bytes
                }
                guard let image = Self.decode(data) else { return .missing }
                if memoryOnly { return .image(image, writtenBytes: 0) }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? data.write(to: file, options: .atomic)) != nil else { return .image(image, writtenBytes: 0) }
                return .image(image, writtenBytes: Int64(data.count))
            }
        }

        private func didWrite(_ bytes: Int64) {
            // 尚未统计过时不在这里扫描目录：启动时的 trimIfNeeded 会建立基准。
            guard let size = diskSize else { return }
            diskSize = size + bytes
            if size + bytes > ImagePipeline.diskLimit { trim() }
        }

        func trimIfNeeded() {
            let total = files().reduce(0) { $0 + $1.size }
            diskSize = total
            if total > ImagePipeline.diskLimit { trim() }
        }

        func diskUsage() -> Int64 {
            if let diskSize { return diskSize }
            let total = files().reduce(0) { $0 + $1.size }
            diskSize = total
            return total
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: directory)
            diskSize = 0
            failures = [:]
        }

        /// 超出上限时按修改时间（读取时会刷新）从旧到新删除，直到降到上限的 80%。
        private func trim() {
            var entries = files()
            var total = entries.reduce(0) { $0 + $1.size }
            defer { diskSize = total }
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
