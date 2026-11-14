import AVFoundation
import Foundation
import UniformTypeIdentifiers
import VelaNetwork

/// 为 AVPlayer 提供 Navidrome 原始 FLAC 的字节区段。跳转可直接读取目标区段。
@MainActor
final class MusicFLACLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let blockSize: Int64 = 512 * 1024
    private static let cachedBlockCount = 8

    private let client: NavidromeClient
    private let url: URL
    private var length: Int64?
    private var cache: [Int64: Data] = [:]
    private var recentBlocks: [Int64] = []
    private var transfers: [Int64: Task<Data, Error>] = [:]
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cancelled = false
    private(set) var receivedBytes: Int64 = 0

    init(client: NavidromeClient, url: URL) {
        self.client = client
        self.url = url
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "vela-flac:///audio.flac")!,
                               options: [AVURLAssetOverrideMIMETypeKey: "audio/flac"])
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    func cancel() {
        cancelled = true
        for request in requests.values { request.cancel() }
        for transfer in transfers.values { transfer.cancel() }
        requests.removeAll()
        transfers.removeAll()
        cache.removeAll()
        recentBlocks.removeAll()
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated {
            guard !cancelled else { return false }
            let key = ObjectIdentifier(request)
            requests[key] = Task {
                defer { requests[key] = nil }
                do {
                    try await respond(to: request)
                    if !Task.isCancelled { request.finishLoading() }
                } catch {
                    if !Task.isCancelled { request.finishLoading(with: error) }
                }
            }
            return true
        }
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    didCancel request: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { requests[ObjectIdentifier(request)]?.cancel() }
    }

    private func respond(to request: AVAssetResourceLoadingRequest) async throws {
        if length == nil { _ = try await block(at: 0) }
        try Task.checkCancellation()
        guard let length else { throw NavidromeError.invalidResponse }
        if let info = request.contentInformationRequest {
            info.contentType = UTType(filenameExtension: "flac")?.identifier
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { return }
        let (requestedEnd, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
        let end = data.requestsAllDataToEndOfResource || overflow ? length : min(length, requestedEnd)
        var offset = max(data.requestedOffset, data.currentOffset)
        while offset < end {
            let start = offset / Self.blockSize * Self.blockSize
            let bytes = try await block(at: start)
            try Task.checkCancellation()
            let first = Int(offset - start)
            let count = Int(min(end - offset, Int64(bytes.count - first)))
            guard count > 0 else { throw NavidromeError.invalidResponse }
            data.respond(with: bytes.subdata(in: first..<(first + count)))
            offset += Int64(count)
        }
    }

    private func block(at start: Int64) async throws -> Data {
        try Task.checkCancellation()
        if let bytes = cache[start] {
            recentBlocks.removeAll { $0 == start }
            recentBlocks.append(start)
            return bytes
        }
        if let transfer = transfers[start] { return try await transfer.value }
        let transfer = Task {
            defer { transfers[start] = nil }
            if length == nil { try await client.checkOriginalFLACRanges(at: url) }
            let (bytes, total) = try await client.originalFLACRange(
                from: url, bytes: start..<(start + Self.blockSize)
            )
            try Task.checkCancellation()
            guard length == nil || length == total else { throw NavidromeError.invalidResponse }
            length = total
            receivedBytes += Int64(bytes.count)
            cache[start] = bytes
            recentBlocks.append(start)
            if recentBlocks.count > Self.cachedBlockCount { cache[recentBlocks.removeFirst()] = nil }
            return bytes
        }
        transfers[start] = transfer
        return try await transfer.value
    }
}
