import Foundation
import Testing
@testable import VelaNetwork

/// Seerr：地址规范化与会话 Cookie 提取。
struct SeerrClientTests {
    @Test func normalizesBaseURL() throws {
        #expect(try SeerrClient(baseURL: " https://req.example.com/api/v1/ ").baseURL.absoluteString == "https://req.example.com")
        #expect(throws: SeerrClient.SeerrError.self) { try SeerrClient(baseURL: "ftp://x") }
    }

    @Test func extractsSessionCookie() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://req.example.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "connect.sid=s%3Aabc.def; Path=/; Expires=Wed, 01 Jan 2027 00:00:00 GMT; HttpOnly"]
        ))
        #expect(SeerrClient.sessionCookie(response) == "connect.sid=s%3Aabc.def")
    }
}
