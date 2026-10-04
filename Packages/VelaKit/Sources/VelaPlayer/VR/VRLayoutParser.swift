import Foundation

/// 从文件名 / 路径 / 标签严格识别 VR 排布（移植自 Vela Android `VrLayoutParser`，规则保持一致）。
///
/// - 必须出现投影标记；标题里单独的 "180"（如《180 天》）不算。
/// - `video3DFormat` 只在已识别投影后补充立体排布。
/// - 已知视频尺寸时以宽高比为最终依据：VR 帧只可能是 1:2 / 1:1 / 2:1 / 4:1，
///   名字带 VR 但比例为 16:9 的文件（已转平面）会被排除；缺少立体标记时按比例推断。
public enum VRLayoutParser {
    /// 宽高比与目标比例的相对误差上限；容纳 5760x2880、8192x4096 及少量裁边 / 非方像素。
    static let aspectTolerance = 0.06

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // 模式为编译期常量，失败即编程错误。
        try! NSRegularExpression(pattern: pattern)
    }

    private static let fisheye220 = regex(#"(?:^|[_\-. ])(?:mkx220|fisheye220|f220)(?:$|[_\-. ])"#)
    private static let fisheye200 = regex(#"(?:^|[_\-. ])(?:mkx200|fisheye200|f200|rf70)(?:$|[_\-. ])"#)
    private static let fisheye190 = regex(#"(?:^|[_\-. ])(?:fisheye190|f190|fisheye|rf52)(?:$|[_\-. ])"#)
    /// DMM 系 VR 番号发布为 180° 等距柱状 SBS；按鱼眼展开会让画面越往边缘越拉伸。
    private static let javStudio = regex(#"(?:^|[_\-. \[【])(?:crvr|kavr|sivr|ipvr|savr|hnvr|pxvr|kmvr|mdvr)[-_]?\d"#)
    private static let halfEquirect = regex(#"(?:^|[_\-. ])(?:vr180|180x180|hequirect)(?:$|[_\-. ])|[_\-.]180[_\-. ]"#)
    private static let equirect = regex(#"(?:^|[_\-. ])(?:vr360|360x180|360x360|equirect)(?:$|[_\-. ])|[_\-.]360[_\-. ]"#)
    private static let stereoSBS = regex(#"(?:^|[_\-. ])(?:sbs|3dh|lr)(?:$|[_\-. ])"#)
    private static let stereoTB = regex(#"(?:^|[_\-. ])(?:tb|ou|3dv)(?:$|[_\-. ])"#)
    private static let stereoMono = regex(#"(?:^|[_\-. ])(?:mono|2d)(?:$|[_\-. ])"#)
    private static let fileExtension = regex(#"\.[a-z0-9]{2,4}$"#)

    public static func parse(
        mediaSourcePath: String? = nil,
        itemPath: String? = nil,
        itemName: String? = nil,
        mediaSourceName: String? = nil,
        tags: [String] = [],
        video3DFormat: String? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil
    ) -> VRLayout? {
        var projection: (VRLayout.Projection, Int)?
        var stereo: VRLayout.Stereo?

        for text in [fileName(mediaSourcePath), fileName(itemPath), itemName, mediaSourceName] {
            guard let normalized = normalize(text) else { continue }
            if projection == nil { projection = scanProjection(normalized) }
            if stereo == nil { stereo = scanStereo(normalized) }
            if projection != nil && stereo != nil { break }
        }

        if projection == nil || stereo == nil {
            for tag in tags {
                guard let scan = scanTag(tag) else { continue }
                if projection == nil { projection = scan.projection }
                if stereo == nil { stereo = scan.stereo }
                if projection != nil && stereo != nil { break }
            }
        }

        guard let (resolvedProjection, inputFOV) = projection else { return nil }
        let declared = stereo ?? stereoFromVideo3DFormat(video3DFormat)
        let resolvedStereo: VRLayout.Stereo
        if let aspect = aspectRatio(videoWidth, videoHeight) {
            let candidates = stereoCandidates(resolvedProjection, aspect: aspect)
            // 尺寸不可能是任何 VR 排布：名字带 VR 但已转成平面的片。
            guard let first = candidates.first else { return nil }
            resolvedStereo = declared.flatMap { candidates.contains($0) ? $0 : nil } ?? first
        } else {
            resolvedStereo = declared ?? .sideBySide
        }
        return VRLayout(projection: resolvedProjection, stereo: resolvedStereo, inputFOV: inputFOV)
    }

    /// 自动识别失败时供用户手动选择的排布。
    public static let manualOptions: [VRLayout] = [
        VRLayout(projection: .halfEquirect, stereo: .sideBySide, inputFOV: 180),
        VRLayout(projection: .halfEquirect, stereo: .topBottom, inputFOV: 180),
        VRLayout(projection: .halfEquirect, stereo: .mono, inputFOV: 180),
        VRLayout(projection: .equirect, stereo: .sideBySide, inputFOV: 360),
        VRLayout(projection: .equirect, stereo: .topBottom, inputFOV: 360),
        VRLayout(projection: .equirect, stereo: .mono, inputFOV: 360),
        VRLayout(projection: .fisheye, stereo: .sideBySide, inputFOV: 190),
        VRLayout(projection: .fisheye, stereo: .sideBySide, inputFOV: 200),
        VRLayout(projection: .fisheye, stereo: .sideBySide, inputFOV: 220)
    ]

    // MARK: - 扫描

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func scanProjection(_ text: String) -> (VRLayout.Projection, Int)? {
        if matches(fisheye220, text) { return (.fisheye, 220) }
        if matches(fisheye200, text) { return (.fisheye, 200) }
        if matches(fisheye190, text) { return (.fisheye, 190) }
        if matches(javStudio, text) { return (.halfEquirect, 180) }
        if matches(halfEquirect, text) { return (.halfEquirect, 180) }
        if matches(equirect, text) { return (.equirect, 360) }
        return nil
    }

    private static func scanStereo(_ text: String) -> VRLayout.Stereo? {
        if matches(stereoMono, text) { return .mono }
        if matches(stereoTB, text) { return .topBottom }
        if matches(stereoSBS, text) { return .sideBySide }
        return nil
    }

    private static func scanTag(_ raw: String) -> (projection: (VRLayout.Projection, Int)?, stereo: VRLayout.Stereo?)? {
        let tag = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty else { return nil }
        let padded = " \(tag) "
        switch tag {
        case "vr", "vr180", "180x180", "hequirect": return ((.halfEquirect, 180), scanStereo(padded))
        case "vr360", "360", "equirect": return ((.equirect, 360), scanStereo(padded))
        case "mkx220", "fisheye220", "f220": return ((.fisheye, 220), scanStereo(padded))
        case "mkx200", "fisheye200", "f200", "rf70": return ((.fisheye, 200), scanStereo(padded))
        case "fisheye190", "f190", "fisheye", "rf52": return ((.fisheye, 190), scanStereo(padded))
        default: break
        }
        guard let normalized = normalize(tag) else { return nil }
        let projection = scanProjection(normalized)
        let stereo = scanStereo(normalized)
        return projection == nil && stereo == nil ? nil : (projection, stereo)
    }

    /// 单眼画面：180° 等距柱状 / 鱼眼为 1:1，360° 等距柱状为 2:1；SBS 宽度翻倍，TB 高度翻倍。
    /// 返回与宽高比吻合的排布，按常见程度排序；为空表示不是 VR 帧。
    private static func stereoCandidates(_ projection: VRLayout.Projection, aspect: Double) -> [VRLayout.Stereo] {
        let eye = projection == .equirect ? 2.0 : 1.0
        let options: [(VRLayout.Stereo, Double)] = [(.sideBySide, eye * 2), (.mono, eye), (.topBottom, eye / 2)]
        return options.filter { abs(aspect / $0.1 - 1) <= aspectTolerance }.map(\.0)
    }

    private static func aspectRatio(_ width: Int?, _ height: Int?) -> Double? {
        guard let width, width > 0, let height, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    private static func stereoFromVideo3DFormat(_ format: String?) -> VRLayout.Stereo? {
        switch format?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "halfsidebyside", "fullsidebyside": .sideBySide
        case "halftopandbottom", "fulltopandbottom": .topBottom
        default: nil
        }
    }

    private static func fileName(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let name = withoutQuery.split(separator: "/").last.map(String.init) ?? withoutQuery
        let last = name.split(separator: "\\").last.map(String.init) ?? name
        return last.isEmpty ? nil : last
    }

    private static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let name = (fileName(raw) ?? raw).lowercased()
        let stripped = fileExtension.stringByReplacingMatches(
            in: name,
            range: NSRange(name.startIndex..., in: name),
            withTemplate: " "
        )
        return " \(stripped) "
    }
}
