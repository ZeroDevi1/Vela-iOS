import AVFoundation
import Foundation

/// 用暂停且静音的播放器准备目标。切换时接管整个播放器，保留已经预热的媒体管线。
@MainActor
final class AVPlayerSeekPreparation {
    let player: AVPlayer
    let item: AVPlayerItem
    private(set) var prerollResult: Bool?
    private var task: Task<Void, Never>?

    init(from original: AVPlayerItem, target: CMTime, tolerance: CMTime, rate: Float, bufferDuration: TimeInterval) {
        item = AVPlayerItem(asset: original.asset)
        item.allowedAudioSpatializationFormats = original.allowedAudioSpatializationFormats
        item.preferredForwardBufferDuration = bufferDuration
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.allowsExternalPlayback = false
        task = Task { [weak self] in
            guard let self else { return }
            let ready = await self.prepare(from: original, target: target, tolerance: tolerance, rate: rate)
            if !Task.isCancelled { self.prerollResult = ready }
        }
    }

    private func prepare(from original: AVPlayerItem, target: CMTime, tolerance: CMTime, rate: Float) async -> Bool {
        do {
            while item.status == .unknown || player.status == .unknown {
                if item.status == .failed || player.status == .failed { return false }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard item.status == .readyToPlay, player.status == .readyToPlay else { return false }
            // 两个条目共享同一个 AVAsset，可以用同一组选项保留原音轨和字幕选择。
            for characteristic in [AVMediaCharacteristic.audible, .legible] {
                try Task.checkCancellation()
                guard let group = try await item.asset.loadMediaSelectionGroup(for: characteristic) else { continue }
                try Task.checkCancellation()
                let selection = original.currentMediaSelection.selectedMediaOption(in: group)
                if selection != nil || group.allowsEmptySelection { item.select(selection, in: group) }
            }
            try Task.checkCancellation()
            guard await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance),
                  !Task.isCancelled, player.status == .readyToPlay else { return false }
            return await player.preroll(atRate: rate)
        } catch {
            return false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        player.cancelPendingPrerolls()
        item.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }
}
