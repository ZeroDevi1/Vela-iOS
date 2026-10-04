import Foundation

/// 片头 / 片尾等可跳过区段，时间单位为秒。
public struct PlaybackSegment: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case intro
        /// 片尾 / 演职员表；到达时提示播放下一集。
        case outro
        case recap
        case preview
    }

    public var kind: Kind
    public var start: TimeInterval
    /// 片尾标记常常没有结束时间，此时为 nil，表示一直到片子结束。
    public var end: TimeInterval?

    public init(kind: Kind, start: TimeInterval, end: TimeInterval?) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// `time` 是否落在区段内。区段起点前 0.5 秒也算，抵消 0.25 秒进度刷新的延迟。
    public func contains(_ time: TimeInterval, duration: TimeInterval) -> Bool {
        let upper = end ?? (duration > 0 ? duration : .greatestFiniteMagnitude)
        return time >= start - 0.5 && time < upper
    }
}

/// 章节。Emby 用 `MarkerType` 标记片头 / 片尾起止点。
public struct MediaChapter: Hashable, Sendable {
    public enum Marker: String, Sendable {
        case chapter = "Chapter"
        case introStart = "IntroStart"
        case introEnd = "IntroEnd"
        case creditsStart = "CreditsStart"
    }

    public var name: String?
    /// 起点，单位秒。
    public var start: TimeInterval
    public var marker: Marker
    /// 章节缩略图 tag；服务器未生成章节图片时为 nil。
    public var imageTag: String?

    public init(name: String?, start: TimeInterval, marker: Marker, imageTag: String? = nil) {
        self.name = name
        self.start = start
        self.marker = marker
        self.imageTag = imageTag
    }

    /// 从 Emby 章节标记推导片头 / 片尾区段；缺少配对的起止点时不生成片头区段。
    public static func segments(from chapters: [MediaChapter]) -> [PlaybackSegment] {
        var result: [PlaybackSegment] = []
        if let start = chapters.first(where: { $0.marker == .introStart }),
           let end = chapters.first(where: { $0.marker == .introEnd && $0.start > start.start }) {
            result.append(PlaybackSegment(kind: .intro, start: start.start, end: end.start))
        }
        if let credits = chapters.first(where: { $0.marker == .creditsStart }) {
            result.append(PlaybackSegment(kind: .outro, start: credits.start, end: nil))
        }
        return result
    }
}
