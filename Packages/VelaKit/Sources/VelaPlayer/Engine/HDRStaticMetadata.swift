import CoreMedia
import CoreVideo
import Foundation

/// 送显画面携带的 HDR10 静态元数据（SMPTE ST 2086 母版显示 + CTA-861.3 内容亮度），用于播放信息显示。
/// 数据格式与 `kCVImageBufferMasteringDisplayColorVolumeKey` / `kCVImageBufferContentLightLevelInfoKey` 相同：
/// HEVC SEI 的大端序载荷（母版显示 24 字节，内容亮度 4 字节）。
public struct HDRStaticMetadata: Equatable, Sendable {
    /// 母版显示最大 / 最小亮度，单位 cd/m²（nits）。
    public var masteringLuminance: (max: Double, min: Double)?
    /// 最大内容亮度（MaxCLL）与最大帧平均亮度（MaxFALL），单位 cd/m²。
    public var contentLightLevel: (maxCLL: Int, maxFALL: Int)?

    /// 两项都缺或长度不符时为 nil。
    public init?(masteringDisplay: Data?, contentLightLevel: Data?) {
        if let data = masteringDisplay, data.count == 24 {
            // 依次为 G、B、R 三原色与白点（各 2 × UInt16），之后是最大、最小亮度（UInt32，单位 0.0001 cd/m²）。
            masteringLuminance = (Double(data.bigEndianUInt32(at: 16)) / 10000, Double(data.bigEndianUInt32(at: 20)) / 10000)
        }
        if let data = contentLightLevel, data.count == 4 {
            self.contentLightLevel = (Int(data.bigEndianUInt16(at: 0)), Int(data.bigEndianUInt16(at: 2)))
        }
        if masteringLuminance == nil, self.contentLightLevel == nil { return nil }
    }

    /// 解码画面的附件（软解由 KSPlayer 补丁 0005 设置；硬解由 VideoToolbox 按格式描述 / 码流 SEI 设置）。
    public init?(pixelBuffer: CVPixelBuffer) {
        self.init(
            masteringDisplay: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
            contentLightLevel: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        )
    }

    /// 轨道格式描述的扩展（容器声明的元数据；直通时没有解码画面，只能读这里）。
    public init?(formatDescription: CMFormatDescription) {
        self.init(
            masteringDisplay: CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume) as? Data,
            contentLightLevel: CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data
        )
    }

    /// 如「母版 1000 / 0.005 nits · MaxCLL 1000 · MaxFALL 400」。
    public var summary: String {
        var parts: [String] = []
        if let masteringLuminance {
            let min = masteringLuminance.min.formatted(.number.precision(.significantDigits(1 ... 4)))
            parts.append("母版 \(Int(masteringLuminance.max.rounded())) / \(min) nits")
        }
        if let contentLightLevel {
            parts.append("MaxCLL \(contentLightLevel.maxCLL) · MaxFALL \(contentLightLevel.maxFALL)")
        }
        return parts.joined(separator: " · ")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.masteringLuminance?.max == rhs.masteringLuminance?.max && lhs.masteringLuminance?.min == rhs.masteringLuminance?.min
            && lhs.contentLightLevel?.maxCLL == rhs.contentLightLevel?.maxCLL && lhs.contentLightLevel?.maxFALL == rhs.contentLightLevel?.maxFALL
    }
}

private extension Data {
    func bigEndianUInt16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[start + $1]) }
    }
}
