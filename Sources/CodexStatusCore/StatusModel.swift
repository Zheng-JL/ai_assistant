import Foundation

public enum SessionPhase: String, Codable, Sendable {
    case running, waitingForInput, idle, backgroundRunning, completed, interrupted, failed, unknown
}

public struct SessionStatus: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let phase: SessionPhase
    public let isUnread: Bool
    public let updatedAt: Date?
    /// When the current run (Codex turn) or status (Claude) began; nil when not applicable.
    public var phaseSince: Date? = nil
    /// Last path component of the working directory; the full path is never kept.
    public var project: String? = nil
    /// Identifier the owning app uses to open this session (Claude's `local_…` host session ID).
    public var openID: String? = nil
}

public struct StatusSnapshot: Sendable {
    public let sampledAt: Date
    public let sessions: [SessionStatus]
    public let runningCount: Int?
    public let completedUnreadCount: Int?
    public let notice: String?
    public let appIsRunning: Bool
    public let inspectedWriterCount: Int
    public var inspectedEngineCount: Int = 0

    public static func unavailable(_ notice: String, appIsRunning: Bool) -> Self {
        .init(sampledAt: Date(), sessions: [], runningCount: nil,
              completedUnreadCount: nil, notice: notice, appIsRunning: appIsRunning,
              inspectedWriterCount: 0)
    }
}

public struct WriterRecord: Sendable {
    public let threadID: String
    public let pid: Int32
    public let processStartedAt: Date
}

public enum SourceError: Error, LocalizedError {
    case unsupported(String)
    case unreadable
    case oversized
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .unreadable: return "无法读取本机状态"
        case .oversized: return "状态记录超过安全读取上限"
        case .malformed: return "状态格式无法识别"
        }
    }
}

func normalizedID(_ value: String) -> String? {
    UUID(uuidString: value)?.uuidString.lowercased()
}

func eventDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return (try? Date(value, strategy: .iso8601.year().month().day().dateSeparator(.dash)
        .time(includingFractionalSeconds: true).timeSeparator(.colon).timeZone(separator: .omitted)))
        ?? (try? Date(value, strategy: .iso8601))
}

func projectName(fromPath path: String?) -> String? {
    guard let path else { return nil }
    let name = (path as NSString).lastPathComponent
        .components(separatedBy: .controlCharacters).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != "/" else { return nil }
    return String(name.prefix(40))
}

/// Claude Desktop only accepts session IDs of this shape in its deep links.
func validClaudeHostSessionID(_ value: String?) -> String? {
    guard let value, value.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
    return value
}

/// Deep link that opens one Claude Code session in Claude Desktop; nil when the ID is not acceptable.
public func claudeSessionURL(_ hostSessionID: String?) -> URL? {
    guard let id = validClaudeHostSessionID(hostSessionID) else { return nil }
    var components = URLComponents()
    components.scheme = "claude"
    components.host = "code"
    components.path = "/continue"
    components.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "desktop_action")]
    return components.url
}

/// Claude's own "sessions waiting for you" screen.
public let claudeNeedsInputURL = URL(string: "claude://code/needs-input?source=desktop_action")!
