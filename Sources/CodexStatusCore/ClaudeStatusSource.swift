import Darwin
import Foundation
import ProcessInspection

struct ClaudeEngineRecord: Sendable {
    let pid: Int32
    let startedAt: Date
}

private final class ClaudeEngineCollector {
    var records: [ClaudeEngineRecord] = []
}

private func receiveClaudeEngine(_ pid: Int32, _ started: Double, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let collector = Unmanaged<ClaudeEngineCollector>.fromOpaque(context).takeUnretainedValue()
    collector.records.append(.init(pid: pid, startedAt: Date(timeIntervalSince1970: started)))
}

// This whitelist deliberately omits socket addresses, credentials, and message bodies.
private struct ClaudeRegistration: Decodable {
    let pid: Int32
    let procStart: String
    let version: String
    let entrypoint: String?
    let kind: String?
    let sessionId: String?
    let startedAt: Double
    let status: String?
    let statusUpdatedAt: Double?
    let hasAgent: Bool
    let spare: Bool
    let project: String?
    let hostSessionID: String?

    enum Keys: String, CodingKey {
        case pid, procStart, version, entrypoint, kind, sessionId, startedAt
        case status, statusUpdatedAt, agent, spare, cwd, hostSessionId
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        pid = try root.decode(Int32.self, forKey: .pid)
        procStart = try root.decode(String.self, forKey: .procStart)
        version = try root.decode(String.self, forKey: .version)
        entrypoint = try root.decodeIfPresent(String.self, forKey: .entrypoint)
        kind = try root.decodeIfPresent(String.self, forKey: .kind)
        sessionId = try root.decodeIfPresent(String.self, forKey: .sessionId)
        startedAt = try root.decode(Double.self, forKey: .startedAt)
        status = try root.decodeIfPresent(String.self, forKey: .status)
        statusUpdatedAt = try root.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)
        hasAgent = try root.contains(.agent) && root.decodeNil(forKey: .agent) == false
        spare = try root.decodeIfPresent(Bool.self, forKey: .spare) ?? false
        project = projectName(fromPath: try root.decodeIfPresent(String.self, forKey: .cwd))
        hostSessionID = try? root.decodeIfPresent(String.self, forKey: .hostSessionId)
    }
}

public actor ClaudeStatusSource {
    private let directory: URL
    private let engineDirectory: URL
    private let processDate: DateFormatter
    private let decoder = JSONDecoder()
    /// The only registration-format version whose field meanings were verified by hand.
    static let verifiedVersion = "2.1.284"

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = home.appendingPathComponent(".claude/sessions").standardizedFileURL
        engineDirectory = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
            .resolvingSymlinksInPath().standardizedFileURL
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        format.isLenient = false
        processDate = format
    }

    public func sample(appPID: Int32?, appBundle: URL?) -> StatusSnapshot {
        guard let appPID else { return .unavailable("Claude 未运行", appIsRunning: false) }
        guard let appBundle else { return .unavailable("无法确认 Claude 应用位置", appIsRunning: true) }
        let collector = ClaudeEngineCollector()
        var appStartedAt = 0.0
        let bundlePath = appBundle.resolvingSymlinksInPath().path
        let enginePath = engineDirectory.path
        let inspected = bundlePath.withCString { bundle in
            enginePath.withCString { engines in
                cs_inspect_claude_engines(appPID, bundle, engines, receiveClaudeEngine,
                    Unmanaged.passUnretained(collector).toOpaque(), &appStartedAt)
            }
        }
        guard inspected == 0 else {
            return .unavailable("无法完整核验 Claude 本机引擎", appIsRunning: true)
        }
        let result = assemble(now: Date(), engines: collector.records)
        guard cs_process_matches(appPID, appStartedAt) == 1,
              collector.records.allSatisfy({
                  cs_process_matches($0.pid, $0.startedAt.timeIntervalSince1970) == 1
              }) else {
            return .unavailable("Claude 进程在采样期间发生变化", appIsRunning: true)
        }
        return result
    }

    func assemble(now: Date, engines: [ClaudeEngineRecord]) -> StatusSnapshot {
        var sessions: [String: SessionStatus] = [:]
        var runningKnown = true
        var unverifiedVersions: Set<String> = []
        for engine in engines {
            do {
                let data = try registrationData(pid: engine.pid)
                let entry = try decoder.decode(ClaudeRegistration.self, from: data)
                guard entry.pid == engine.pid, Self.looksLikeVersion(entry.version),
                      let started = processDate.date(from: entry.procStart),
                      abs(started.timeIntervalSince(engine.startedAt)) < 1,
                      entry.startedAt.isFinite,
                      entry.startedAt / 1000 >= engine.startedAt.timeIntervalSince1970 - 1,
                      entry.startedAt / 1000 <= now.timeIntervalSince1970 + 5 else {
                    throw SourceError.malformed
                }
                if entry.version != Self.verifiedVersion { unverifiedVersions.insert(entry.version) }
                if entry.spare { continue }
                guard !entry.hasAgent else {
                    throw SourceError.unsupported("Claude agent 会话来源尚未核验")
                }
                guard entry.entrypoint == "claude-desktop", entry.kind == "interactive" else {
                    throw SourceError.unsupported("Claude 会话来源尚未核验")
                }
                guard let id = entry.sessionId.flatMap(normalizedID),
                      let milliseconds = entry.statusUpdatedAt, milliseconds.isFinite,
                      milliseconds >= entry.startedAt,
                      milliseconds / 1000 <= now.timeIntervalSince1970 + 5 else {
                    throw SourceError.malformed
                }
                let phase: SessionPhase
                switch entry.status {
                case "busy": phase = .running
                case "waiting": phase = .waitingForInput
                case "idle": phase = .idle
                case "shell": phase = .backgroundRunning
                default: throw SourceError.unsupported("Claude 运行状态尚未核验")
                }
                let session = SessionStatus(id: id, title: title(from: data, id: id),
                    phase: phase, isUnread: false,
                    updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                    phaseSince: Date(timeIntervalSince1970: milliseconds / 1000), project: entry.project,
                    openID: validClaudeHostSessionID(entry.hostSessionID))
                if let old = sessions[id] {
                    // Concurrent holders can disagree; never hide a running holder behind idle.
                    if old.phase != phase {
                        sessions[id] = .init(id: id, title: old.title, phase: .unknown,
                                             isUnread: false, updatedAt: session.updatedAt)
                        throw SourceError.malformed
                    }
                    if (old.updatedAt ?? .distantPast) >= (session.updatedAt ?? .distantPast) { continue }
                }
                sessions[id] = session
            } catch {
                runningKnown = false
            }
        }
        let ordered = sessions.values.sorted {
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.id < $1.id
        }
        return .init(sampledAt: now, sessions: ordered,
                     runningCount: runningKnown ? ordered.filter { $0.phase == .running }.count : nil,
                     completedUnreadCount: nil,
                     notice: notice(runningKnown: runningKnown, unverified: unverifiedVersions),
                     appIsRunning: true, inspectedWriterCount: 0, inspectedEngineCount: engines.count)
    }

    private static func looksLikeVersion(_ value: String) -> Bool {
        value.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,4}$"#, options: .regularExpression) != nil
    }

    private func notice(runningKnown: Bool, unverified: Set<String>) -> String? {
        var parts: [String] = []
        if !unverified.isEmpty {
            parts.append("Claude 版本 \(unverified.sorted().joined(separator: "、")) 未经验证（已验证 \(Self.verifiedVersion)），状态可能不准")
        }
        if !runningKnown { parts.append("部分 Claude 会话来源或状态无法确认") }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private func registrationData(pid: Int32) throws -> Data {
        let parent = directory.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parent >= 0 else { throw SourceError.unreadable }
        defer { close(parent) }
        let folder = openat(parent, "sessions", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard folder >= 0 else { throw SourceError.unreadable }
        defer { close(folder) }
        let descriptor = "\(pid).json".withCString {
            openat(folder, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SourceError.unreadable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG else { throw SourceError.unreadable }
        guard metadata.st_size <= 64 * 1024 else { throw SourceError.oversized }
        let data = try file.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw SourceError.oversized }
        return data
    }

    private func title(from data: Data, id: String) -> String {
        struct Title: Decodable { let name: String? }
        let raw = (try? decoder.decode(Title.self, from: data).name) ?? ""
        let title = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Claude Code \(id.prefix(8))" : String(title.prefix(256))
    }
}
