import Foundation
import VelaCore

/// 服务器管理（仅管理员账号可用）：系统信息、活动会话、计划任务、媒体库扫描。Jellyfin / Emby 接口一致。
public struct ServerSystemInfo: Decodable, Sendable {
    public var serverName: String?
    public var version: String?
    public var operatingSystem: String?
    public var operatingSystemDisplayName: String?
    public var localAddress: String?
    public var hasPendingRestart: Bool?
    public var hasUpdateAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case operatingSystem = "OperatingSystem"
        case operatingSystemDisplayName = "OperatingSystemDisplayName"
        case localAddress = "LocalAddress"
        case hasPendingRestart = "HasPendingRestart"
        case hasUpdateAvailable = "HasUpdateAvailable"
    }
}

public struct ServerSession: Decodable, Identifiable, Sendable {
    public struct NowPlaying: Decodable, Sendable {
        public var name: String?
        public var seriesName: String?
        public var runTimeTicks: Int64?
        enum CodingKeys: String, CodingKey { case name = "Name", seriesName = "SeriesName", runTimeTicks = "RunTimeTicks" }
    }

    public struct PlayState: Decodable, Sendable {
        public var isPaused: Bool?
        public var playMethod: String?
        public var positionTicks: Int64?
        enum CodingKeys: String, CodingKey { case isPaused = "IsPaused", playMethod = "PlayMethod", positionTicks = "PositionTicks" }
    }

    public struct Transcoding: Decodable, Sendable {
        public var videoCodec: String?
        public var audioCodec: String?
        public var isVideoDirect: Bool?
        public var bitrate: Int?
        public var transcodeReasons: [String]?
        enum CodingKeys: String, CodingKey {
            case videoCodec = "VideoCodec", audioCodec = "AudioCodec", isVideoDirect = "IsVideoDirect"
            case bitrate = "Bitrate", transcodeReasons = "TranscodeReasons"
        }
    }

    public var id: String
    public var userName: String?
    public var client: String?
    public var deviceName: String?
    public var applicationVersion: String?
    public var remoteEndPoint: String?
    public var nowPlaying: NowPlaying?
    public var playState: PlayState?
    public var transcoding: Transcoding?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userName = "UserName"
        case client = "Client"
        case deviceName = "DeviceName"
        case applicationVersion = "ApplicationVersion"
        case remoteEndPoint = "RemoteEndPoint"
        case nowPlaying = "NowPlayingItem"
        case playState = "PlayState"
        case transcoding = "TranscodingInfo"
    }
}

public struct ScheduledTask: Decodable, Identifiable, Sendable {
    public struct LastResult: Decodable, Sendable {
        public var status: String?
        public var endTime: Date?
        public var errorMessage: String?
        enum CodingKeys: String, CodingKey { case status = "Status", endTime = "EndTimeUtc", errorMessage = "ErrorMessage" }
    }

    public var id: String
    public var name: String
    public var category: String?
    /// `Idle` / `Running` / `Cancelling`。
    public var state: String?
    public var progress: Double?
    public var lastResult: LastResult?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", category = "Category", state = "State"
        case progress = "CurrentProgressPercentage", lastResult = "LastExecutionResult"
    }
}

/// 服务器活动日志的一条记录（`/System/ActivityLog/Entries`，Jellyfin 与 Emby 相同）。
public struct ActivityLogEntry: Decodable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var overview: String?
    public var shortOverview: String?
    /// 例如 `SessionStarted`、`VideoPlayback`、`UserCreated`。
    public var type: String?
    public var date: Date?
    /// `Information` / `Warning` / `Error`（Emby 为 `Info` / `Warn` / `Error`）。
    public var severity: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", overview = "Overview", shortOverview = "ShortOverview"
        case type = "Type", date = "Date", severity = "Severity"
    }

    /// 严重级别归一：警告或错误时返回对应值，信息类为 nil。
    public var level: Level? {
        switch severity?.lowercased() {
        case "warning", "warn": .warning
        case "error", "critical", "fatal": .error
        default: nil
        }
    }

    public enum Level: Sendable { case warning, error }
}

private struct UserPolicyDTO: Decodable {
    struct Policy: Decodable {
        var isAdministrator: Bool?
        enum CodingKeys: String, CodingKey { case isAdministrator = "IsAdministrator" }
    }
    var policy: Policy?
    enum CodingKeys: String, CodingKey { case policy = "Policy" }
}

extension MediaServerClient {
    /// 当前账号是否为管理员；非管理员访问管理接口会被拒绝，界面据此隐藏入口。
    public func isAdministrator() async throws -> Bool {
        let dto = try await httpClient.decode(UserPolicyDTO.self, APIRequest("/Users/\(userID)"), baseURL: baseURL, headers: requestHeaders)
        return dto.policy?.isAdministrator == true
    }

    public func systemInfo() async throws -> ServerSystemInfo {
        try await httpClient.decode(ServerSystemInfo.self, APIRequest("/System/Info"), baseURL: baseURL, headers: requestHeaders)
    }

    /// 最近 16 分钟内活跃的会话。
    public func activeSessions() async throws -> [ServerSession] {
        try await httpClient.decode(
            [ServerSession].self,
            APIRequest("/Sessions", query: [.init(name: "ActiveWithinSeconds", value: "960")]),
            baseURL: baseURL, headers: requestHeaders
        )
    }

    public func scheduledTasks() async throws -> [ScheduledTask] {
        try await httpClient.decode(
            [ScheduledTask].self,
            APIRequest("/ScheduledTasks", query: [.init(name: "IsHidden", value: "false")]),
            baseURL: baseURL, headers: requestHeaders
        )
    }

    public func runScheduledTask(id: String) async throws {
        _ = try await httpClient.data(APIRequest("/ScheduledTasks/Running/\(id)", method: .post), baseURL: baseURL, headers: requestHeaders)
    }

    /// 活动日志（新的在前），分页读取；返回本页记录与总数。
    public func activityLog(startIndex: Int, limit: Int = 50) async throws -> (entries: [ActivityLogEntry], total: Int?) {
        let result = try await httpClient.decode(
            QueryResult<ActivityLogEntry>.self,
            APIRequest("/System/ActivityLog/Entries", query: [
                .init(name: "StartIndex", value: String(startIndex)),
                .init(name: "Limit", value: String(limit)),
            ]),
            baseURL: baseURL, headers: requestHeaders
        )
        return (result.items, result.totalRecordCount)
    }

    /// 扫描全部媒体库。
    public func refreshLibraries() async throws {
        _ = try await httpClient.data(APIRequest("/Library/Refresh", method: .post), baseURL: baseURL, headers: requestHeaders)
    }
}
