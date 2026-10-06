import Foundation

/// 当前设备与播放内核的解码能力，用于生成发给服务器的 DeviceProfile。
///
/// 由 VelaPlayer 按设备实测（VideoToolbox / AVPlayer）生成，网络层只消费，不自行猜测设备型号。
public struct PlaybackCapabilities: Sendable, Hashable {
    /// 硬件 AV1 解码：A17 Pro / M3 及之后的芯片才有，软件解码 4K AV1 会严重掉帧。
    public var supportsAV1: Bool
    public var supportsHEVC: Bool
    /// 杜比视界 Profile 5 / 8.x 单层；AVPlayer 不支持 Profile 7 双层。
    public var supportsDolbyVision: Bool
    public var supportsHDR10: Bool
    /// 音频最大声道数（直通或解码后下混前）。
    public var maxAudioChannels: Int
    /// E-AC3（含杜比全景声 JOC）直通；false 时服务器把 E-AC3 转为 AC3 / AAC。
    public var supportsEAC3: Bool
    /// 直放与转码的码率上限，单位 bit/s。
    public var maxStreamingBitrate: Int
    /// 视频宽度上限（像素）；nil 为不限制。超过时服务器缩小分辨率重新编码，用于本机解码器打不开的超高分辨率
    /// 片源（如 8192 宽的 8K VR）。
    public var maxVideoWidth: Int?

    public init(
        supportsAV1: Bool,
        supportsHEVC: Bool = true,
        supportsDolbyVision: Bool,
        supportsHDR10: Bool,
        maxAudioChannels: Int = 8,
        supportsEAC3: Bool = true,
        maxStreamingBitrate: Int = 160_000_000,
        maxVideoWidth: Int? = nil
    ) {
        self.maxVideoWidth = maxVideoWidth
        self.supportsEAC3 = supportsEAC3
        self.supportsAV1 = supportsAV1
        self.supportsHEVC = supportsHEVC
        self.supportsDolbyVision = supportsDolbyVision
        self.supportsHDR10 = supportsHDR10
        self.maxAudioChannels = maxAudioChannels
        self.maxStreamingBitrate = maxStreamingBitrate
    }
}
