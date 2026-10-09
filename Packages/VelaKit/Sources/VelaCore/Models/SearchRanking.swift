import Foundation

/// 搜索结果的相关度排序（与 Android `SearchViewModel.textSearchMatch` 相同的规则）：服务器搜索还会匹配简介、
/// 演职员等字段，按标题 / 原标题与关键词的匹配程度排序，标题完全不含关键词的结果不显示。
public enum SearchRanking {
    /// 匹配程度，值越小越靠前。
    public enum Match: Int, Comparable, Sendable {
        /// 去掉空白与标点后完全相同。
        case exact
        /// 忽略大小写完全相同。
        case exactText
        /// 标题包含整个关键词。
        case phrase
        /// 去掉空白与标点后包含。
        case normalizedPhrase
        /// 关键词的每个词都出现在标题的某个词中。
        case allWords
        /// 单个关键词出现在标题的某个词中。
        case singleWord

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 多个候选文本（标题、原标题）中最好的匹配；都不匹配时为 nil。
    public static func bestMatch(_ query: String, in texts: [String?]) -> Match? {
        texts.compactMap { $0 }.compactMap { match(text: $0, query: query) }.min()
    }

    /// 按匹配程度稳定排序并丢弃不匹配的条目。
    public static func rank<T>(_ items: [T], query: String, texts: (T) -> [String?]) -> [T] {
        var scored: [(offset: Int, item: T, match: Match)] = []
        for (offset, item) in items.enumerated() {
            if let match = bestMatch(query, in: texts(item)) { scored.append((offset, item, match)) }
        }
        scored.sort { lhs, rhs in lhs.match == rhs.match ? lhs.offset < rhs.offset : lhs.match < rhs.match }
        return scored.map(\.item)
    }

    static func match(text: String, query: String) -> Match? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !trimmedQuery.isEmpty else { return nil }
        let lowerQuery = trimmedQuery.lowercased()
        let lowerText = text.lowercased()
        let normalizedQuery = normalized(trimmedQuery)
        let normalizedText = normalized(text)
        let queryWords = words(lowerQuery)
        let tokens = words(lowerText)
        let allWordsMatch = !queryWords.isEmpty && queryWords.allSatisfy { word in tokens.contains { $0.contains(word) } }

        if normalizedText == normalizedQuery { return .exact }
        if lowerText == lowerQuery { return .exactText }
        if lowerText.contains(lowerQuery) { return .phrase }
        if !normalizedQuery.isEmpty, normalizedText.contains(normalizedQuery) { return .normalizedPhrase }
        if allWordsMatch { return .allWords }
        if queryWords.count == 1, let word = queryWords.first, tokens.contains(where: { $0.contains(word) }) { return .singleWord }
        return nil
    }

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: separators).joined()
    }

    private static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
}
