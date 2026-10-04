import AVFoundation
import CoreMedia
import VelaCore
import VideoToolbox

/// 实测当前设备的解码与 HDR 能力，而不是按型号查表：同一系统版本下 iPad / Mac 芯片差异很大。
///
/// 目标设备参考：iPhone 16 Pro（A18 Pro，AV1 硬解）、iPad Pro 11" 2022（M2，无 AV1 硬解）、MacBook Air M4（AV1 硬解）。
public enum PlaybackCapabilityProbe {
    public static func current() -> PlaybackCapabilities {
        // availableHDRModes 已在 iOS 26 弃用且 macOS 不可用。系统只给出整体 HDR 资格：
        // 当前支持 HDR 的 Apple 设备（A12+ / Apple 芯片）同时支持 HDR10 与杜比视界 Profile 5 / 8.x。
        let hdr = AVPlayer.eligibleForHDRPlayback
        return PlaybackCapabilities(
            supportsAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            supportsHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            supportsDolbyVision: hdr,
            supportsHDR10: hdr
        )
    }
}
