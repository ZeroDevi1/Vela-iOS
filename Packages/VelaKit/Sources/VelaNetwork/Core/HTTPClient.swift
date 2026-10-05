import Foundation
import VelaCore

public enum APIError: LocalizedError, Sendable {
    case invalidURL(String)
    case transport(URLError)
    case http(status: Int, body: String?)
    case decoding(String)
    case unauthorized
    /// 登录接口返回 401：用户名或密码错误。与会话失效区分，避免误导用户。
    case invalidCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            "无效的服务器地址：\(raw)"
        case .transport(let error):
            error.localizedDescription
        case .http(let status, let body):
            Self.httpMessage(status: status, body: body)
        case .decoding(let detail):
            "无法解析服务器响应：\(detail)"
        case .unauthorized:
            "登录已失效，请重新登录"
        case .invalidCredentials:
            "用户名或密码错误"
        }
    }

    /// 服务器的错误正文通常是一句可读原因（例如 Emby 的「账号已被禁用」），截取后附在提示里。
    private static func httpMessage(status: Int, body: String?) -> String {
        let base = status == 403 ? "服务器拒绝访问（HTTP 403）" : "服务器返回错误（HTTP \(status)）"
        let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !detail.isEmpty, !detail.hasPrefix("<"), detail.count <= 200 else { return base }
        return base + "：" + detail
    }
}

/// 发往服务器的请求描述。路径相对于服务器 base URL（含 `/emby` 前缀时也只写其后的部分）。
public struct APIRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", delete = "DELETE" }

    public var method: Method
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        _ path: String,
        method: Method = .get,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeout = timeout
    }

    public static func post(_ path: String, json: some Encodable & Sendable, query: [URLQueryItem] = []) throws -> APIRequest {
        APIRequest(path, method: .post, query: query, body: try JSONEncoder().encode(json))
    }
}

/// 无状态 HTTP 执行器。鉴权头由调用方传入，便于同一 client 并发服务多台服务器。
public struct HTTPClient: Sendable {
    private let session: URLSession
    /// 连接层失败（超时、无法连接主机等）时回调，参数为请求的 base URL；多线路路由据此触发重新探测。
    /// 用户取消与 HTTP 状态码错误不会回调。
    private let onTransportFailure: (@Sendable (URL) -> Void)?

    public init(session: URLSession = .shared, onTransportFailure: (@Sendable (URL) -> Void)? = nil) {
        self.session = session
        self.onTransportFailure = onTransportFailure
    }

    public func data(
        _ request: APIRequest,
        baseURL: URL,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try Self.makeURL(baseURL: baseURL, path: request.path, query: request.query)
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            if Self.isConnectivityFailure(error) { onTransportFailure?(baseURL) }
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, body: nil)
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw APIError.unauthorized
        default:
            Log.network.error("HTTP \(http.statusCode, privacy: .public) \(request.method.rawValue, privacy: .public) \(request.path, privacy: .public)")
            throw APIError.http(status: http.statusCode, body: String(data: data.prefix(512), encoding: .utf8))
        }
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        _ request: APIRequest,
        baseURL: URL,
        headers: [String: String]
    ) async throws -> T {
        let (data, _) = try await self.data(request, baseURL: baseURL, headers: headers)
        do {
            return try JSONDecoder.server.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// 说明线路本身不可达的错误；取消、证书等问题不代表换线路能解决。
    static func isConnectivityFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            true
        default:
            false
        }
    }

    /// 拼接 base URL 与相对路径，保留 base 自身的路径前缀（例如反代下的 `/jellyfin`、Emby 的 `/emby`）。
    public static func makeURL(baseURL: URL, path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString)
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let relative = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + relative
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw APIError.invalidURL(baseURL.absoluteString + path)
        }
        return url
    }
}

extension JSONDecoder {
    /// Jellyfin / Emby 的日期带 7 位小数秒，标准 ISO8601 解析不了，这里统一按字符串宽松解析。
    static let server: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ServerDate.parse(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "日期格式无法识别：\(raw)"))
        }
        return decoder
    }()
}

enum ServerDate {
    static func parse(_ raw: String) -> Date? {
        // 截断到毫秒，兼容 .NET 的 7 位小数。
        var value = raw
        if let dot = value.firstIndex(of: ".") {
            let fractionEnd = value[dot...].firstIndex { !$0.isNumber && $0 != "." } ?? value.endIndex
            let fraction = value[value.index(after: dot)..<fractionEnd].prefix(3)
            value = String(value[..<dot]) + "." + fraction + String(value[fractionEnd...])
        }
        if !value.hasSuffix("Z") && !value.contains("+") && value.count <= 23 { value += "Z" }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(value) { return date }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}
