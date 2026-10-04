import OSLog

/// 统一的日志分类。日志中禁止输出 token、密码和完整的带鉴权参数的 URL。
public enum Log {
    private static let subsystem = "app.vela"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let data = Logger(subsystem: subsystem, category: "data")
    public static let player = Logger(subsystem: subsystem, category: "player")
}
