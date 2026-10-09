import Foundation

/// 下载画质。原画下载服务器上的原文件；其余由服务器按码率上限转码为 HLS 后下载。
public enum DownloadQuality: String, Codable, CaseIterable, Sendable {
    case original, high, medium, low

    public var title: String {
        switch self {
        case .original: "原画"
        case .high: "1080p（8 Mbps）"
        case .medium: "720p（4 Mbps）"
        case .low: "480p（1.5 Mbps）"
        }
    }

    /// 转码码率上限（bit/s）；原画为 nil。
    public var maxBitrate: Int? {
        switch self {
        case .original: nil
        case .high: 8_000_000
        case .medium: 4_000_000
        case .low: 1_500_000
        }
    }
}

/// 一条下载记录。媒体文件放在应用支持目录下，记录只保存相对路径，避免沙盒路径变化后失效。
public struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        /// `paused`：任务被挂起（后台会话保留任务，继续时从断点接着下载）。
        case queued, downloading, paused, completed, failed
    }

    /// `serverID/itemID/quality`：同一条目不同画质可并存。
    public var id: String
    public var serverID: String
    public var itemID: String
    public var title: String
    /// 剧集名 + 集号等副标题。
    public var subtitle: String?
    public var posterURL: URL?
    public var quality: DownloadQuality
    public var state: State
    /// 0...1。
    public var progress: Double
    /// 相对下载目录的路径（文件下载），或相对用户主目录的路径（HLS `.movpkg`，系统决定位置）。
    public var relativePath: String?
    public var isHLS: Bool
    public var fileSize: Int64?
    public var errorMessage: String?
    public var createdAt: Date
    /// 服务器转码会话；HLS 下载结束后需通知服务器停止转码。
    public var playSessionID: String?
    /// 转码下载时选择的音轨（`MediaStream.Index`）；原画下载包含全部音轨，为 nil。
    public var audioStreamIndex: Int?

    public init(
        serverID: String, itemID: String, title: String, subtitle: String?, posterURL: URL?,
        quality: DownloadQuality, isHLS: Bool, playSessionID: String? = nil, audioStreamIndex: Int? = nil,
        createdAt: Date = .now
    ) {
        self.id = Self.makeID(serverID: serverID, itemID: itemID, quality: quality)
        self.serverID = serverID
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.quality = quality
        self.state = .queued
        self.progress = 0
        self.isHLS = isHLS
        self.createdAt = createdAt
        self.playSessionID = playSessionID
        self.audioStreamIndex = audioStreamIndex
    }

    public static func makeID(serverID: String, itemID: String, quality: DownloadQuality) -> String {
        "\(serverID)/\(itemID)/\(quality.rawValue)"
    }
}

/// 下载占用空间估算（开始下载前与可用空间比较，与 Android 版相同的估算方式）。
public enum DownloadEstimate {
    /// 转码时音频的估算码率（bit/s）。
    static let audioBitrate = 192_000

    /// 预计占用的字节数；缺少所需信息时为 nil。
    /// - 原画：原文件大小。
    /// - 限定码率：原文件码率不超过上限且有大小时下载原文件（`PlaybackResolver.resolveDownload` 的规则），
    ///   否则按（视频码率上限与原码率中较小者 + 音频码率）× 时长估算。
    public static func bytes(quality: DownloadQuality, fileSize: Int64?, sourceBitrate: Int?, runTimeTicks: Int64?) -> Int64? {
        guard let limit = quality.maxBitrate else { return fileSize }
        if let sourceBitrate, sourceBitrate <= limit, let fileSize { return fileSize }
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        let seconds = Double(runTimeTicks) / 10_000_000
        let videoBitrate = min(limit, sourceBitrate ?? limit)
        return Int64(Double(videoBitrate + audioBitrate) * seconds / 8)
    }
}

/// 离线文件的播放内核：系统框架能打开的容器用系统内核，其余（MKV 等）用 MPV。
public enum OfflinePlayback {
    static let systemExtensions: Set<String> = ["mp4", "m4v", "mov", "movpkg", "m3u8"]

    public static func prefersSystemEngine(for url: URL) -> Bool {
        systemExtensions.contains(url.pathExtension.lowercased())
    }
}
