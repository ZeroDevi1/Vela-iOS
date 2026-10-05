import CoreGraphics
import Foundation
import ImageIO
import Network
import Photos
import UniformTypeIdentifiers
import VelaCore
import VelaNetwork
import VelaPlayer
#if os(iOS)
import UIKit
#endif

// MARK: - 音轨 / 字幕记忆与首选语言

/// 记住用户在某部作品中手动选择的音轨 / 字幕语言（剧集按剧，电影按条目），下次播放同一作品时优先选择。
/// 只记语言而不记轨道序号：同一部剧不同集的轨道顺序可能不同。
enum TrackMemory {
    /// 记录字幕「关闭」的特殊值。
    static let subtitleOff = "off"

    static func workID(for item: MediaItem) -> String {
        "\(item.serverID)/\(item.seriesID ?? item.id)"
    }

    static func audioLanguage(for item: MediaItem) -> String? {
        UserDefaults.standard.string(forKey: "trackMemory.audio.\(workID(for: item))")
    }

    static func subtitleLanguage(for item: MediaItem) -> String? {
        UserDefaults.standard.string(forKey: "trackMemory.subtitle.\(workID(for: item))")
    }

    static func rememberAudio(_ language: String?, for item: MediaItem) {
        guard let language, !language.isEmpty else { return }
        UserDefaults.standard.set(language, forKey: "trackMemory.audio.\(workID(for: item))")
    }

    static func rememberSubtitle(_ language: String?, for item: MediaItem) {
        guard let language, !language.isEmpty else { return }
        UserDefaults.standard.set(language, forKey: "trackMemory.subtitle.\(workID(for: item))")
    }

    /// 在候选轨道中找第一条语言匹配的；`language` 为空时返回 nil（交给服务器默认）。
    static func match(_ language: String?, in streams: [MediaStreamInfo]) -> MediaStreamInfo? {
        MediaSelection.firstStream(matching: language, in: streams)
    }
}

// MARK: - 截图

enum ScreenshotSaver {
    /// 按设置编码截图；失败返回 nil。
    static func encode(_ image: CGImage, format: ScreenshotFormat, quality: Double) -> Data? {
        let type: UTType = switch format {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, format == .png ? nil : options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 保存到相册：只申请「仅添加」权限，不读取用户照片。
    static func saveToPhotos(_ data: Data) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            Log.player.error("截图保存到相册失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

// MARK: - 网络类型

/// 当前网络是否为蜂窝 / 个人热点 / 低数据模式，用于选择 Wi-Fi 或流量下的磁盘预缓存大小。
@MainActor
final class NetworkStatus {
    static let shared = NetworkStatus()

    private(set) var isExpensive = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in NetworkStatus.shared.isExpensive = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "app.vela.network-status"))
    }
}

// MARK: - 播放器独立亮度

#if os(iOS)
/// 「播放器独立亮度」：进入播放器时切到上次播放器内的亮度，离开（或切后台）时恢复系统亮度。
@MainActor
enum PlayerBrightness {
    private static var systemBrightness: CGFloat?

    static var screen: UIScreen? { OrientationController.activeScene?.screen }

    static func enter(_ preferences: PlayerPreferences) {
        guard preferences.independentBrightness, let screen, systemBrightness == nil else { return }
        systemBrightness = screen.brightness
        screen.brightness = CGFloat(preferences.playerBrightness)
    }

    static func leave() {
        guard let value = systemBrightness else { return }
        systemBrightness = nil
        screen?.brightness = value
    }

    /// 手势调节亮度时调用：独立亮度开启时记下播放器亮度。
    static func didAdjust(_ value: Double, preferences: PlayerPreferences) {
        if preferences.independentBrightness { preferences.playerBrightness = value }
    }
}
#endif
