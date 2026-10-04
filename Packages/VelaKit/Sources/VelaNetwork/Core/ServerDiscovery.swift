import Foundation
import VelaCore

/// 用户输入地址的规范化与服务器类型识别。
public enum ServerDiscovery {
    /// 把用户输入转换为候选 base URL，按尝试顺序排列。
    ///
    /// - 未写协议时先试 https 再试 http（局域网地址反过来，因为 NAS 通常只开 http）。
    /// - Emby 的接口挂在 `/emby` 下；用户没写时追加一个带 `/emby` 的候选。
    public static func candidates(for input: String) -> [URL] {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard !raw.isEmpty else { return [] }

        let schemes: [String]
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            schemes = [""]
        } else {
            let host = raw.split(separator: "/").first.map { String($0.split(separator: ":").first ?? "") } ?? ""
            schemes = LineRouting.isLANHost(host) ? ["http://", "https://"] : ["https://", "http://"]
        }

        var result: [URL] = []
        for scheme in schemes {
            let base = scheme + raw
            let variants = base.lowercased().hasSuffix("/emby") ? [base] : [base, base + "/emby"]
            for variant in variants {
                if let url = URL(string: variant), url.host() != nil, !result.contains(url) {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// 根据响应头与 `/System/Info/Public` 推断服务器类型；均无法判断时返回 nil，由调用方按 Jellyfin 处理。
    public static func detectKind(info: PublicSystemInfo, applicationHeader: String?) -> MediaServerKind? {
        let header = applicationHeader?.lowercased() ?? ""
        if header.contains("jellyfin") { return .jellyfin }
        if header.contains("emby") { return .emby }
        let product = info.productName?.lowercased() ?? ""
        if product.contains("jellyfin") { return .jellyfin }
        if product.contains("emby") { return .emby }
        // Emby 4.x 版本号与 Jellyfin 10.x 不重叠。
        if info.version?.hasPrefix("4.") == true { return .emby }
        return nil
    }
}
