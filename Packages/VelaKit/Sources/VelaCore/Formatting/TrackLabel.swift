import Foundation

/// 音轨 / 字幕的展示信息：服务器原始标题 + 中文语言名 + 采样率 / 码率 + 默认 / 强制 / 外挂标记。
/// 详情页播放源卡片与播放器内面板共用，保证两处显示一致。
public struct TrackLabel: Hashable, Sendable {
    public enum Flag: String, Hashable, Sendable {
        case `default` = "默认"
        case forced = "强制"
        case external = "外挂"
    }

    /// 服务器给出的标题，去掉了与 `flags` 重复的「Default / Forced / External」后缀。
    public var title: String
    /// 中文语言名，例如「日语」「国语」「简体中文」；无法识别时为 nil。
    public var languageName: String?
    /// 补充参数，例如「48 kHz」「192 kbps」「5.1」。
    public var details: [String]
    public var flags: [Flag]

    public init(title: String, languageName: String? = nil, details: [String] = [], flags: [Flag] = []) {
        self.title = title
        self.languageName = languageName
        self.details = details
        self.flags = flags
    }

    /// 第二行文字：语言名、参数与标记，以「 · 」连接；全部为空时为 nil。
    public var detailLine: String? {
        let parts = [languageName].compactMap { $0 } + details + flags.map(\.rawValue)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 构造 `TrackLabel` 所需的轨道属性，与网络层 DTO 解耦。
public struct TrackAttributes: Sendable {
    public enum Kind: Sendable { case audio, subtitle }

    public var kind: Kind
    public var index: Int
    /// ISO 639-1 / 639-2 语言代码，也可能是 `chs` / `zh-TW` 等非标准写法。
    public var language: String?
    /// 封装内的轨道标题（例如「简日双语」「Cantonese」）。
    public var title: String?
    /// 服务器拼好的展示标题（例如「Japanese - AC3 - Stereo - Default」）。
    public var displayTitle: String?
    public var codec: String?
    public var channels: Int?
    public var channelLayout: String?
    /// 采样率（Hz）。
    public var sampleRate: Int?
    /// 码率（bit/s）。
    public var bitRate: Int?
    public var isDefault: Bool
    public var isForced: Bool
    public var isExternal: Bool

    public init(
        kind: Kind,
        index: Int,
        language: String? = nil,
        title: String? = nil,
        displayTitle: String? = nil,
        codec: String? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleRate: Int? = nil,
        bitRate: Int? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false
    ) {
        self.kind = kind
        self.index = index
        self.language = language
        self.title = title
        self.displayTitle = displayTitle
        self.codec = codec
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
    }
}

public enum TrackLabelFormatter {
    public static func label(for track: TrackAttributes) -> TrackLabel {
        let fallback = track.kind == .audio ? "音轨 \(track.index)" : "字幕 \(track.index)"
        let rawTitle = track.displayTitle ?? track.title ?? track.language ?? fallback
        var title = stripFlagSuffixes(rawTitle)
        // Emby 对没有标题的字幕给出「(SUBRIP)」这类只有编码名的显示标题，改成常见写法（SRT）。
        if track.kind == .subtitle, let format = subtitleFormatName(title.trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))) {
            title = format
        }

        var details: [String] = []
        if track.kind == .audio {
            if let rate = track.sampleRate, rate > 0 {
                let khz = Double(rate) / 1000
                details.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
            }
            if let bitRate = track.bitRate, bitRate > 0 {
                details.append(bitRate >= 1_000_000
                    ? String(format: "%.1f Mbps", Double(bitRate) / 1_000_000)
                    : "\(bitRate / 1000) kbps")
            }
        }

        var flags: [TrackLabel.Flag] = []
        if track.isDefault { flags.append(.default) }
        if track.isForced { flags.append(.forced) }
        if track.isExternal { flags.append(.external) }

        let name = languageName(code: track.language, hints: [track.title, track.displayTitle].compactMap { $0 }, kind: track.kind)
        return TrackLabel(title: title.isEmpty ? fallback : title, languageName: name, details: details, flags: flags)
    }

    /// 中文语言名。中文音轨区分「国语 / 粤语」，中文字幕区分「简体 / 繁体」，依据语言代码与轨道标题中的关键词。
    public static func languageName(code: String?, hints: [String] = [], kind: TrackAttributes.Kind) -> String? {
        let normalizedCode = code?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let hintText = hints.joined(separator: " ").lowercased()

        if isChinese(code: normalizedCode, hints: hintText) {
            return chineseName(code: normalizedCode, hints: hintText, kind: kind)
        }
        guard !normalizedCode.isEmpty, normalizedCode != "und", normalizedCode != "unknown" else { return nil }
        let base = normalizedCode.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? normalizedCode
        if let name = languageNames[base] { return name }
        // 表外语言交给系统本地化；系统也不认识时不显示，避免把代码原样当成名称。
        let localized = Locale(identifier: "zh-Hans").localizedString(forLanguageCode: base)
        return localized.flatMap { $0.lowercased() == base ? nil : $0 }
    }

    // MARK: - 中文

    private static let chineseCodes: Set<String> = ["zh", "chi", "zho", "chs", "cht", "cmn", "yue", "cn", "hk", "tw"]

    private static func isChinese(code: String, hints: String) -> Bool {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        if chineseCodes.contains(base) { return true }
        // 部分外挂字幕没有语言代码，只能靠标题判断。
        guard code.isEmpty || code == "und" else { return false }
        return containsAny(hints, ["chinese", "中文", "简", "繁", "国语", "粤语", "chs", "cht"])
    }

    private static func chineseName(code: String, hints: String, kind: TrackAttributes.Kind) -> String {
        switch kind {
        case .audio:
            if code.hasPrefix("yue") || containsAny(hints, ["cantonese", "粤语", "粵語", "粤配"]) { return "粤语" }
            return "国语"
        case .subtitle:
            let traditional = code.hasPrefix("cht") || containsAny(code, ["hant", "-tw", "-hk", "-mo"])
                || containsAny(hints, ["traditional", "繁", "cht", "big5", "zh-hant", "zh-tw", "zh-hk"])
            let simplified = code.hasPrefix("chs") || containsAny(code, ["hans", "-cn", "-sg"])
                || containsAny(hints, ["simplified", "简", "chs", "zh-hans", "zh-cn"])
            // 同时出现时以代码为准；代码无法区分则按标题中先出现的关键词。
            if simplified && !traditional { return "简体中文" }
            if traditional && !simplified { return "繁体中文" }
            if simplified && traditional {
                if code.hasPrefix("chs") || code.contains("hans") { return "简体中文" }
                if code.hasPrefix("cht") || code.contains("hant") { return "繁体中文" }
                return "简繁中文"
            }
            return "中文"
        }
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    /// 常见语言代码。系统本地化对 ISO 639-2 的 B 代码（如 `fre` / `ger`）支持不全，这里显式列出。
    private static let languageNames: [String: String] = [
        "ja": "日语", "jpn": "日语",
        "en": "英语", "eng": "英语",
        "ko": "韩语", "kor": "韩语",
        "fr": "法语", "fre": "法语", "fra": "法语",
        "de": "德语", "ger": "德语", "deu": "德语",
        "es": "西班牙语", "spa": "西班牙语",
        "it": "意大利语", "ita": "意大利语",
        "pt": "葡萄牙语", "por": "葡萄牙语",
        "ru": "俄语", "rus": "俄语",
        "th": "泰语", "tha": "泰语",
        "vi": "越南语", "vie": "越南语",
        "id": "印尼语", "ind": "印尼语",
        "ms": "马来语", "may": "马来语", "msa": "马来语",
        "ar": "阿拉伯语", "ara": "阿拉伯语",
        "hi": "印地语", "hin": "印地语",
        "nl": "荷兰语", "dut": "荷兰语", "nld": "荷兰语",
        "pl": "波兰语", "pol": "波兰语",
        "tr": "土耳其语", "tur": "土耳其语",
        "sv": "瑞典语", "swe": "瑞典语",
        "da": "丹麦语", "dan": "丹麦语",
        "no": "挪威语", "nor": "挪威语", "nob": "挪威语",
        "fi": "芬兰语", "fin": "芬兰语",
        "uk": "乌克兰语", "ukr": "乌克兰语",
        "he": "希伯来语", "heb": "希伯来语",
        "el": "希腊语", "gre": "希腊语", "ell": "希腊语",
        "cs": "捷克语", "cze": "捷克语", "ces": "捷克语",
        "hu": "匈牙利语", "hun": "匈牙利语"
    ]

    // MARK: - 标题清理

    /// Jellyfin / Emby 的 DisplayTitle 会把默认 / 强制 / 外挂拼在末尾，与标记徽章重复，这里去掉。
    private static let flagSuffixes = [
        "default", "forced", "external", "默认", "强制", "外部", "外挂"
    ]

    /// 字幕编码名 → 常见写法；不是已知编码名时返回 nil。
    static func subtitleFormatName(_ codec: String) -> String? {
        switch codec.lowercased() {
        case "subrip", "srt": "SRT"
        case "ass": "ASS"
        case "ssa": "SSA"
        case "webvtt", "vtt": "WebVTT"
        case "pgssub", "hdmv_pgs_subtitle", "pgs": "PGS"
        case "dvdsub", "dvd_subtitle", "vobsub": "VobSub"
        case "mov_text", "tx3g": "MP4 文本"
        case "ttml": "TTML"
        default: nil
        }
    }

    static func stripFlagSuffixes(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for suffix in flagSuffixes {
                for pattern in [" - \(suffix)", " (\(suffix))", "(\(suffix))", " [\(suffix)]"] {
                    if result.lowercased().hasSuffix(pattern) {
                        result = String(result.dropLast(pattern.count)).trimmingCharacters(in: .whitespaces)
                        changed = true
                    }
                }
            }
        }
        return stripFlagWordsInParentheses(result)
    }

    /// 处理标记夹在括号中间的写法，例如 Emby 中文界面的「Chinese Simplified (默认 ASS)」→「Chinese Simplified (ASS)」；
    /// 括号内只剩标记时整组去掉。
    static func stripFlagWordsInParentheses(_ title: String) -> String {
        let pattern = /\(([^()]*)\)/
        var result = title
        for match in title.matches(of: pattern).reversed() {
            let words = match.output.1.split(whereSeparator: \.isWhitespace)
            let kept = words.filter { !flagSuffixes.contains($0.lowercased()) }
            guard kept.count != words.count else { continue }
            let replacement = kept.isEmpty ? "" : "(" + kept.joined(separator: " ") + ")"
            result.replaceSubrange(match.range, with: replacement)
        }
        return result.replacing(/\s{2,}/, with: " ").trimmingCharacters(in: .whitespaces)
    }
}
