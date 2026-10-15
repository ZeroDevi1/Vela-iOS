import Foundation
import Testing
@testable import VelaNetwork

/// 元数据编辑整份回写：只替换编辑字段，其余字段（演职员、外部 id 等）保持原样；识别结果原样提交。
struct MetadataEditTests {
    @Test func editingKeepsUnrelatedFields() throws {
        var json: [String: Any] = [
            "Name": "旧标题", "ProductionYear": 2001, "Genres": ["剧情"],
            "Studios": [["Name": "A", "Id": "1"]], "People": [["Name": "演员"]], "ProviderIds": ["Tmdb": "42"],
            "PremiereDate": "2001-05-01T00:00:00.0000000Z",
        ]
        var metadata = EditableMetadata(json: json)
        #expect(metadata.name == "旧标题")
        #expect(metadata.premiereDate != nil)
        metadata.name = "新标题"
        metadata.genres = ["剧情", "科幻"]
        metadata.studios = ["A", "B"]
        metadata.overview = ""
        metadata.apply(to: &json)
        #expect(json["Name"] as? String == "新标题")
        #expect(json["Genres"] as? [String] == ["剧情", "科幻"])
        #expect((json["Studios"] as? [[String: Any]])?.first?["Id"] as? String == "1")
        #expect((json["People"] as? [[String: Any]])?.count == 1)
        #expect(json["ProviderIds"] as? [String: String] == ["Tmdb": "42"])
        #expect(json["Overview"] == nil)
    }

    @Test func mergingTagsIgnoresCaseAndKeepsOrder() {
        let merged = MediaServerClient.mergedTags(["收藏", "vr180_sbs", "4K"], adding: ["VR360_TB"], removing: ["VR180_SBS"])
        #expect(merged == ["收藏", "4K", "VR360_TB"])
        #expect(MediaServerClient.mergedTags(["vr360_tb"], adding: ["VR360_TB"], removing: []) == ["vr360_tb"])
    }

    @Test func parsesRemoteSearchResults() throws {
        let data = Data(#"[{"Name":"盗梦空间","ProductionYear":2010,"ProviderIds":{"Tmdb":"27205"},"SearchProviderName":"TheMovieDb","Extra":1}]"#.utf8)
        let results = try MediaServerClient.parseRemoteSearch(data)
        #expect(results.first?.name == "盗梦空间")
        #expect(results.first?.providerIDs["Tmdb"] == "27205")
        let raw = try JSONSerialization.jsonObject(with: results[0].raw) as? [String: Any]
        #expect(raw?["Extra"] as? Int == 1)
    }
}
