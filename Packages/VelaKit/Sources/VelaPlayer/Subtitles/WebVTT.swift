import Foundation

/// 一条字幕，时间单位秒。
public struct SubtitleCue: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 精简的 WebVTT 解析器：只取时间与纯文本。
///
/// 服务器把 SRT / ASS 等转换为 WebVTT 时会保留少量标记（`<i>`、`<c.xxx>`、ASS 的 `{\an8}` 覆盖码），
/// 这里统一剥离；样式化渲染（ASS 特效）留给 MPV 内核。
public enum WebVTTParser {
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""),
                  end > start else { continue }
            let body = lines[(timingIndex + 1)...]
                .map(stripMarkup)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// 解析 `hh:mm:ss.mmm` 或 `mm:ss.mmm`（SRT 风格的逗号小数也接受）。
    static func timestamp(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = value.split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var seconds: TimeInterval = 0
        for field in fields {
            guard let number = Double(field) else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<[^>]*>|\{\\[^}]*\}"#)

    static func stripMarkup(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        let stripped = tagPattern.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\N", with: "\n")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 已加载的字幕轨，按时间查询当前应显示的文本。
public struct SubtitleTrack: Sendable {
    public let cues: [SubtitleCue]
    /// 字幕整体偏移（秒），正值表示字幕延后显示。
    public var delay: TimeInterval = 0

    public init(cues: [SubtitleCue]) {
        self.cues = cues
    }

    /// 二分查找起点不晚于 `time` 的 cue，再向前合并重叠的 cue（多行同时显示）。
    public func text(at time: TimeInterval) -> String? {
        let t = time - delay
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= t { low = mid + 1 } else { high = mid }
        }
        var active: [String] = []
        var index = low - 1
        // 重叠的 cue 通常相邻；最多回看 8 条，避免长字幕文件中退化为线性扫描。
        while index >= 0, low - index <= 8 {
            let cue = cues[index]
            if cue.start <= t && t < cue.end { active.insert(cue.text, at: 0) }
            index -= 1
        }
        return active.isEmpty ? nil : active.joined(separator: "\n")
    }
}
