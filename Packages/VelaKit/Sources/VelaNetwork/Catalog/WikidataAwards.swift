import Foundation
import VelaCore

/// 奖项（与 Android `AwardsCatalog` 相同的奖项与奖项类别，Wikidata QID）。
public struct AwardDefinition: Identifiable, Hashable, Sendable {
    public struct Category: Hashable, Sendable {
        public var qid: String
        public var label: String
    }

    public var id: String
    public var label: String
    public var categories: [Category]
}

public enum AwardsCatalog {
    private static func award(_ id: String, _ label: String, _ categories: [(String, String)]) -> AwardDefinition {
        AwardDefinition(id: id, label: label, categories: categories.map { .init(qid: $0.0, label: $0.1) })
    }

    public static let awards: [AwardDefinition] = [
        award("oscars", "奥斯卡金像奖", [
            ("Q102427", "最佳影片"), ("Q103360", "最佳导演"), ("Q103916", "最佳男主角"), ("Q103618", "最佳女主角"),
            ("Q106291", "最佳男配角"), ("Q106301", "最佳女配角"), ("Q107258", "最佳改编剧本"), ("Q41417", "最佳原创剧本"),
            ("Q281939", "最佳剪辑"), ("Q131520", "最佳摄影"), ("Q277751", "最佳美术设计"), ("Q277536", "最佳服装设计"),
            ("Q488651", "最佳原创配乐"), ("Q112243", "最佳原创歌曲"), ("Q830079", "最佳音效"), ("Q393686", "最佳视觉效果"),
            ("Q487136", "最佳化妆与发型设计"), ("Q105304", "最佳国际影片"), ("Q106800", "最佳动画长片"), ("Q111332", "最佳纪录长片"),
        ]),
        award("bafta", "英国电影学院奖", [
            ("Q139184", "最佳影片"), ("Q2663714", "最佳英国影片"), ("Q787131", "最佳导演"), ("Q400007", "最佳男主角"),
            ("Q687123", "最佳女主角"), ("Q548389", "最佳男配角"), ("Q787123", "最佳女配角"), ("Q41375", "最佳原创剧本"),
            ("Q739694", "最佳改编剧本"), ("Q778870", "最佳摄影"), ("Q787145", "最佳剪辑"), ("Q787098", "最佳原创音乐"),
            ("Q739633", "最佳音效"), ("Q787127", "最佳特殊视觉效果"), ("Q2925687", "最佳非英语片"),
        ]),
        award("berlin", "柏林国际电影节", [
            ("Q154590", "金熊奖"), ("Q664212", "银熊奖 · 评审团大奖"), ("Q321207", "银熊奖 · 评审团奖"),
            ("Q706031", "银熊奖 · 最佳导演"), ("Q819973", "银熊奖 · 最佳男演员"), ("Q182836", "泰迪熊奖"),
            ("Q28799939", "最佳纪录片"),
        ]),
        award("cannes", "戛纳国际电影节", [
            ("Q179808", "金棕榈奖"), ("Q844804", "评审团大奖"), ("Q510175", "最佳导演"), ("Q840286", "最佳女演员"),
            ("Q586140", "最佳男演员"),
        ]),
        award("emmys", "黄金时段艾美奖", [
            ("Q20714679", "杰出限定剧"), ("Q989453", "限定剧 / 电视电影最佳男主角"), ("Q989447", "限定剧 / 电视电影最佳女主角"),
            ("Q945887", "限定剧 / 电视电影最佳男配角"), ("Q989449", "限定剧 / 电视电影最佳女配角"),
            ("Q3403229", "限定剧 / 电视电影最佳导演"), ("Q2604800", "剧情类最佳客串男演员"), ("Q17009259", "限定剧 / 电视电影最佳配乐"),
        ]),
        award("golden_globes", "金球奖", [
            ("Q1011509", "剧情类最佳影片"), ("Q670282", "音乐 / 喜剧类最佳影片"), ("Q593098", "剧情类最佳男主角"),
            ("Q463085", "剧情类最佳女主角"), ("Q181883", "音乐 / 喜剧类最佳男主角"), ("Q822907", "电影类最佳女配角"),
            ("Q586356", "最佳导演"), ("Q849124", "最佳编剧"), ("Q1422140", "最佳原创配乐"), ("Q387380", "最佳非英语片"),
            ("Q1255198", "剧情类最佳剧集"), ("Q1257501", "剧情类剧集最佳女主角"),
        ]),
        award("independent_spirit", "独立精神奖", [
            ("Q2295041", "最佳导演"), ("Q2544851", "最佳女主角"), ("Q2544859", "最佳男主角"), ("Q2294705", "最佳女配角"),
            ("Q2294693", "最佳男配角"), ("Q1170507", "最佳编剧"), ("Q1171956", "最佳处女作剧本"), ("Q1170500", "最佳处女作"),
            ("Q1170493", "最佳摄影"), ("Q2295011", "最佳国际影片"), ("Q3910543", "约翰·卡萨维茨奖"),
        ]),
        award("saturn", "土星奖", [
            ("Q1131772", "最佳科幻电影"), ("Q956597", "最佳奇幻电影"), ("Q115705", "最佳恐怖电影"), ("Q115737", "最佳动作 / 冒险电影"),
            ("Q16294258", "最佳惊悚电影"), ("Q1231643", "最佳动画电影"), ("Q1267697", "最佳国际电影"), ("Q1265702", "最佳导演"),
            ("Q1259362", "最佳男主角"), ("Q1413741", "最佳女主角"), ("Q1258647", "最佳男配角"), ("Q1257399", "最佳女配角"),
            ("Q981030", "最佳编剧"), ("Q2226481", "最佳美术设计"), ("Q7426776", "最佳剪辑"), ("Q971008", "最佳服装"),
            ("Q2116650", "最佳化妆"), ("Q8555", "最佳特效"), ("Q1757366", "最佳音乐"),
        ]),
        award("sundance", "圣丹斯电影节", [
            ("Q3774974", "美国剧情片评审团大奖"), ("Q2366088", "纪录片评审团大奖"), ("Q969394", "世界电影评审团大奖"),
            ("Q1419872", "美国剧情片观众奖"), ("Q2366084", "美国最佳导演"),
        ]),
        award("toronto", "多伦多国际电影节", [
            ("Q39087364", "观众选择奖"), ("Q16034468", "最佳加拿大电影"),
        ]),
        award("venice", "威尼斯国际电影节", [
            ("Q209459", "金狮奖"), ("Q944480", "评审团大奖"), ("Q2089923", "沃尔皮杯 · 最佳男演员"),
            ("Q2089918", "沃尔皮杯 · 最佳女演员"), ("Q2504862", "酷儿金狮奖"),
        ]),
    ]
}

/// 获奖 / 提名作品的引用：Wikidata 中带 TMDB id 的电影或剧集。
public struct AwardTitleRef: Hashable, Sendable {
    public var tmdbID: Int
    public var mediaType: CatalogTitle.MediaType
    public var year: Int?
}

/// Wikidata SPARQL 查询（与 Android `WikidataAwardsClient` 相同的查询）：作品本身获奖，或人物因该作品获奖
/// （`pq:P1686` 指向作品）；只保留有 TMDB 电影（P4947）/ 剧集（P4983）id 的作品，按年份倒序。
public actor WikidataAwardsClient {
    public enum Mode: Sendable { case winners, nominees }

    public static let shared = WikidataAwardsClient()

    private let session: URLSession
    /// 本次运行内缓存：Wikidata 公共查询服务有频率限制，奖项数据也很少变化。
    private var cache: [String: [AwardTitleRef]] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 一次查询多个类别，返回每个类别的作品（最多 `limit` 部）。查询失败时抛出错误。
    public func titles(categories: [String], mode: Mode, limit: Int = 300) async throws -> [String: [AwardTitleRef]] {
        var result: [String: [AwardTitleRef]] = [:]
        let uncached = categories.filter { cache[Self.key($0, mode)] == nil }
        if !uncached.isEmpty {
            let fetched = try await query(uncached, mode: mode)
            for qid in uncached { cache[Self.key(qid, mode)] = Array((fetched[qid] ?? []).prefix(limit)) }
        }
        for qid in categories { result[qid] = cache[Self.key(qid, mode)] ?? [] }
        return result
    }

    private static func key(_ qid: String, _ mode: Mode) -> String { "\(qid)|\(mode)" }

    private func query(_ categories: [String], mode: Mode) async throws -> [String: [AwardTitleRef]] {
        let property = mode == .nominees ? "P1411" : "P166"
        let values = categories.map { "wd:\($0)" }.joined(separator: " ")
        let sparql = """
        SELECT ?cat ?tmdb ?type (MAX(?yr) AS ?year) WHERE {
          VALUES ?cat { \(values) }
          { ?work wdt:\(property) ?cat . }
          UNION { ?person p:\(property) ?st . ?st ps:\(property) ?cat ; pq:P1686 ?work . }
          { ?work wdt:P4947 ?tmdb . BIND("movie" AS ?type) }
          UNION { ?work wdt:P4983 ?tmdb . BIND("tv" AS ?type) }
          OPTIONAL { ?work wdt:P577 ?d . BIND(YEAR(?d) AS ?yr) }
        }
        GROUP BY ?cat ?tmdb ?type
        ORDER BY DESC(?year)
        """
        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [.init(name: "format", value: "json"), .init(name: "query", value: sparql)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        // Wikidata 要求可识别的 User-Agent。
        request.setValue("Vela/awards (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data)
    }

    /// 解析 SPARQL JSON 结果，按类别分组（保持服务器给出的年份倒序）。
    static func parse(_ data: Data) throws -> [String: [AwardTitleRef]] {
        struct Response: Decodable {
            struct Results: Decodable { var bindings: [[String: Value]] }
            struct Value: Decodable { var value: String }
            var results: Results
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var grouped: [String: [AwardTitleRef]] = [:]
        for binding in response.results.bindings {
            guard let category = binding["cat"]?.value.split(separator: "/").last.map(String.init), !category.isEmpty,
                  let tmdb = binding["tmdb"]?.value, let tmdbID = Int(tmdb),
                  let type = (binding["type"]?.value).flatMap(CatalogTitle.MediaType.init(rawValue:))
            else { continue }
            let year = binding["year"].flatMap { Int($0.value) }
            grouped[category, default: []].append(AwardTitleRef(tmdbID: tmdbID, mediaType: type, year: year))
        }
        return grouped
    }
}
