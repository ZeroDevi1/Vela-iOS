import AVFoundation
import Foundation
import Observation
import VelaCore
import VelaNetwork

/// 离线下载。原文件用后台 `URLSession` 下载；转码 HLS 用 `AVAssetDownloadURLSession`（系统管理 `.movpkg`）。
///
/// 记录存 JSON；媒体文件放在 Application Support/Vela/Downloads 并排除 iCloud 备份。
/// 后台会话在应用被挂起时继续下载，系统唤醒应用时经 `handleBackgroundEvents` 交回完成回调。
@MainActor
@Observable
public final class DownloadManager {
    public private(set) var records: [DownloadRecord] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private var hlsSession: AVAssetDownloadURLSession!
    @ObservationIgnored private let bridge = DelegateBridge()
    /// 系统在后台完成下载后唤醒应用时给的回调，事件处理完毕后调用。静态存储：App 代理拿不到管理器实例。
    private static var backgroundCompletion: [String: () -> Void] = [:]
    /// HLS 完成后用来结束服务器转码；由 AppModel 注入。
    @ObservationIgnored public var clientProvider: ((String) -> MediaServerClient?)?

    static let fileSessionID = "app.vela.downloads.file"
    static let hlsSessionID = "app.vela.downloads.hls"

    public init() {
        let base = URL.applicationSupportDirectory.appending(path: "Vela", directoryHint: .isDirectory)
        directory = base.appending(path: "Downloads", directoryHint: .isDirectory)
        indexURL = base.appending(path: "downloads.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        load()

        bridge.manager = self
        let fileConfiguration = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fileConfiguration.sessionSendsLaunchEvents = true
        fileSession = URLSession(configuration: fileConfiguration, delegate: bridge, delegateQueue: nil)
        let hlsConfiguration = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        hlsConfiguration.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfiguration, assetDownloadDelegate: bridge, delegateQueue: nil)
        // 应用被系统终止后重新启动：仍在进行的后台任务会继续回调；没有任务的「下载中」记录标记为失败，允许重试。
        Task { await reconcileInterrupted() }
    }

    // MARK: - 查询

    public func record(serverID: String, itemID: String) -> [DownloadRecord] {
        records.filter { $0.serverID == serverID && $0.itemID == itemID }
    }

    /// 可用于下载的剩余空间（字节，`volumeAvailableCapacityForImportantUsage`：系统可为用户主动操作清理出的空间）；
    /// 取不到时为 nil。
    nonisolated public static func availableCapacity() -> Int64? {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 已完成下载的本地地址；文件丢失时返回 nil。
    public func localURL(for record: DownloadRecord) -> URL? {
        guard record.state == .completed, let path = record.relativePath else { return nil }
        let url = record.isHLS ? URL.homeDirectory.appending(path: path) : directory.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 操作

    public func enqueue(
        item: MediaItem, source: PlaybackResolver.DownloadSource, quality: DownloadQuality, posterURL: URL?,
        audioStreamIndex: Int? = nil
    ) {
        var record = DownloadRecord(
            serverID: item.serverID, itemID: item.id,
            title: item.seriesName ?? item.name,
            subtitle: item.episodeLabel.map { "\($0) · \(item.name)" },
            posterURL: posterURL, quality: quality, isHLS: source.isHLS, playSessionID: source.playSessionID,
            audioStreamIndex: source.isHLS ? audioStreamIndex : nil
        )
        if let existing = records.firstIndex(where: { $0.id == record.id }) {
            guard records[existing].state == .failed else { return }
            removeFile(of: records[existing])
            records.remove(at: existing)
        }
        record.state = .downloading
        if source.isHLS {
            let task = hlsSession.makeAssetDownloadTask(
                downloadConfiguration: AVAssetDownloadConfiguration(asset: AVURLAsset(url: source.url), title: record.title)
            )
            task.taskDescription = record.id
            task.resume()
        } else {
            let task = fileSession.downloadTask(with: source.url)
            task.taskDescription = "\(record.id)|\(source.fileExtension)"
            task.resume()
        }
        records.insert(record, at: 0)
        save()
    }

    /// 暂停：挂起后台任务（保留已下载部分），记录标为 `paused`。
    public func pause(_ record: DownloadRecord) {
        guard record.state == .downloading || record.state == .queued else { return }
        setState(.paused, for: record.id)
        Task { for task in await tasks(for: record.id) { task.suspend() } }
    }

    /// 继续：恢复被挂起的任务。任务已不存在（例如被系统清理）时标为失败，由用户重试。
    public func resume(_ record: DownloadRecord) {
        guard record.state == .paused else { return }
        setState(.downloading, for: record.id)
        Task {
            let tasks = await tasks(for: record.id)
            guard !tasks.isEmpty else {
                markFailed(record.id, message: "下载任务已失效，请重试")
                return
            }
            for task in tasks { task.resume() }
        }
    }

    public var hasActiveDownloads: Bool {
        records.contains { $0.state == .downloading || $0.state == .queued }
    }

    public var hasPausedDownloads: Bool {
        records.contains { $0.state == .paused }
    }

    public func pauseAll() {
        for record in records where record.state == .downloading || record.state == .queued { pause(record) }
    }

    public func resumeAll() {
        for record in records where record.state == .paused { resume(record) }
    }

    public func delete(_ record: DownloadRecord) {
        cancelTasks(for: record.id)
        removeFile(of: record)
        records.removeAll { $0.id == record.id }
        save()
        stopEncoding(record)
    }

    // MARK: - 后台事件

    /// App 代理的 `handleEventsForBackgroundURLSession` 调用。
    public static func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        backgroundCompletion[identifier] = completion
    }

    fileprivate func sessionFinishedEvents(_ identifier: String?) {
        guard let identifier, let completion = Self.backgroundCompletion.removeValue(forKey: identifier) else { return }
        completion()
    }

    // MARK: - 回调处理

    fileprivate func updateProgress(id: String, progress: Double) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].progress = min(max(progress, 0), 1)
        // 挂起后仍可能收到已在队列中的进度回调，不能把暂停状态改回下载中。
        if records[index].state != .paused { records[index].state = .downloading }
    }

    fileprivate func finishFile(id: String, fileExtension: String, temporary: URL) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let name = id.replacingOccurrences(of: "/", with: "_") + "." + fileExtension
        let destination = directory.appending(path: name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            records[index].relativePath = name
            records[index].fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            records[index].state = .completed
            records[index].progress = 1
        } catch {
            records[index].state = .failed
            records[index].errorMessage = error.localizedDescription
        }
        save()
    }

    fileprivate func finishHLS(id: String, location: URL) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        // 系统给出的 .movpkg 位置在用户主目录下，只保存相对路径（沙盒路径会变）。
        records[index].relativePath = location.relativePath
        save()
    }

    fileprivate func complete(id: String, error: (any Error)?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            records[index].state = .failed
            records[index].errorMessage = error.localizedDescription
        } else if records[index].isHLS {
            records[index].state = records[index].relativePath == nil ? .failed : .completed
            records[index].progress = 1
        }
        save()
        if records[index].isHLS { stopEncoding(records[index]) }
    }

    // MARK: - 内部

    private func reconcileInterrupted() async {
        let fileTasks = await fileSession.allTasks
        let hlsTasks = await hlsSession.allTasks
        let active = Set((fileTasks + hlsTasks).compactMap { $0.taskDescription?.split(separator: "|").first.map(String.init) })
        var changed = false
        for index in records.indices where (records[index].state == .downloading || records[index].state == .paused)
            && !active.contains(records[index].id) {
            records[index].state = .failed
            records[index].errorMessage = "下载被中断，请重试"
            changed = true
        }
        if changed { save() }
    }

    private func cancelTasks(for id: String) {
        Task { for task in await tasks(for: id) { task.cancel() } }
    }

    private func tasks(for id: String) async -> [URLSessionTask] {
        (await fileSession.allTasks + hlsSession.allTasks).filter {
            $0.taskDescription?.split(separator: "|").first.map(String.init) == id
        }
    }

    private func setState(_ state: DownloadRecord.State, for id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        save()
    }

    private func markFailed(_ id: String, message: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .failed
        records[index].errorMessage = message
        save()
    }

    private func removeFile(of record: DownloadRecord) {
        guard let path = record.relativePath else { return }
        let url = record.isHLS ? URL.homeDirectory.appending(path: path) : directory.appending(path: path)
        try? FileManager.default.removeItem(at: url)
    }

    private func stopEncoding(_ record: DownloadRecord) {
        guard record.isHLS, let session = record.playSessionID, let client = clientProvider?(record.serverID) else { return }
        Task { try? await client.stopActiveEncodings(playSessionID: session) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.data.error("下载记录保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// URLSession / AVAssetDownloadURLSession 的代理：回调在会话队列上，统一转回主 actor。
private final class DelegateBridge: NSObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?

    private static func parse(_ description: String?) -> (id: String, ext: String)? {
        guard let parts = description?.split(separator: "|", maxSplits: 1), let id = parts.first else { return nil }
        return (String(id), parts.count > 1 ? String(parts[1]) : "")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = Self.parse(downloadTask.taskDescription), totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak manager] in manager?.updateProgress(id: info.id, progress: progress) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = Self.parse(downloadTask.taskDescription) else { return }
        // 临时文件在回调返回后即被删除：先同步移到暂存位置，再交给主 actor 归档。
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor [weak manager] in manager?.complete(id: info.id, error: error) }
            return
        }
        Task { @MainActor [weak manager] in manager?.finishFile(id: info.id, fileExtension: info.ext, temporary: staging) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = Self.parse(assetDownloadTask.taskDescription) else { return }
        Task { @MainActor [weak manager] in manager?.finishHLS(id: info.id, location: location) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let info = Self.parse(assetDownloadTask.taskDescription), timeRangeExpectedToLoad.duration.seconds > 0 else { return }
        let loaded = loadedTimeRanges.map(\.timeRangeValue.duration.seconds).reduce(0, +)
        let progress = loaded / timeRangeExpectedToLoad.duration.seconds
        Task { @MainActor [weak manager] in manager?.updateProgress(id: info.id, progress: progress) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let info = Self.parse(task.taskDescription) else { return }
        // 普通下载成功时已在 didFinishDownloadingTo 处理；这里只处理失败与 HLS 收尾。
        if error == nil, task is URLSessionDownloadTask { return }
        let sendableError = error.map { $0 as NSError }
        Task { @MainActor [weak manager] in manager?.complete(id: info.id, error: sendableError) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        Task { @MainActor [weak manager] in manager?.sessionFinishedEvents(identifier) }
    }
}
