import Foundation

public struct TranscriptMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let text: String
    public let at: Date?
}

public struct SessionTranscript: Sendable, Equatable {
    public let provider: String        // "claude" | "codex"
    public let sessionID: String
    public let project: String?
    public let messages: [TranscriptMessage]
}

private struct ClaudeContent: Decodable {
    struct Block: Decodable {
        let type: String?
        let text: String?
    }
    let text: String

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) { text = string; return }
        let blocks = try single.decode([Block].self)
        text = blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
    }
}

private struct ClaudeLine: Decodable {
    struct Message: Decodable { let content: ClaudeContent? }
    let type: String?
    let timestamp: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let cwd: String?
    let message: Message?
}

private struct CodexLine: Decodable {
    struct Block: Decodable {
        let type: String?
        let text: String?
    }
    struct Payload: Decodable {
        let type: String?
        let role: String?
        let cwd: String?
        let content: [Block]?
    }
    let type: String?
    let timestamp: String?
    let payload: Payload?
}

/// Pulls the human-readable conversation out of Claude Code and Codex session logs.
/// Tool calls, tool output, hidden reasoning, images, system/developer text and injected context are left out.
public struct TranscriptExtractor: Sendable {
    private let claudeRoot: URL
    private let codexRoot: URL
    private static let maxFileBytes: UInt64 = 300 * 1024 * 1024
    private static let claudeNoise = ["<command-", "<local-command", "<system-reminder", "<ide_", "<user-prompt-submit-hook",
                                      "<task-notification", "Caveat:", "[Request interrupted"]
    private static let codexNoise = ["<environment_context", "<user_instructions", "# AGENTS.md", "<INSTRUCTIONS",
                                     "<permissions", "<turn_aborted", "<user_action", "<collaboration_mode"]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        claudeRoot = home.appendingPathComponent(".claude/projects").resolvingSymlinksInPath().standardizedFileURL
        codexRoot = home.appendingPathComponent(".codex/sessions").resolvingSymlinksInPath().standardizedFileURL
    }

    public func extract(dayKey: String, calendar: Calendar = .current, now: Date = Date()) -> [SessionTranscript] {
        let start = calendar.startOfDay(for: now)
        var result: [SessionTranscript] = []
        for url in files(under: claudeRoot, since: start, prefix: nil) {
            if let session = readClaude(url, dayKey: dayKey, calendar: calendar) { result.append(session) }
        }
        for url in files(under: codexRoot, since: start, prefix: "rollout-") {
            if let session = readCodex(url, dayKey: dayKey, calendar: calendar) { result.append(session) }
        }
        return result.sorted { ($0.messages.first?.at ?? .distantPast) < ($1.messages.first?.at ?? .distantPast) }
    }

    private func files(under root: URL, since start: Date, prefix: String?) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl",
                  prefix.map({ url.lastPathComponent.hasPrefix($0) }) ?? true,
                  let modified = values.contentModificationDate, modified >= start,
                  UInt64(values.fileSize ?? 0) <= Self.maxFileBytes else { continue }
            found.append(url.standardizedFileURL)
        }
        return found.sorted { $0.path < $1.path }
    }

    private func readClaude(_ url: URL, dayKey: String, calendar: Calendar) -> SessionTranscript? {
        guard let sessionID = normalizedID(url.deletingPathExtension().lastPathComponent) else { return nil }  // skips sub-agent files
        let decoder = JSONDecoder()
        var messages: [TranscriptMessage] = []
        var project: String?
        forEachLine(in: url) { line in
            guard line.range(of: Data("\"message\"".utf8)) != nil,
                  line.range(of: Data("tool_result".utf8)) == nil,
                  let parsed = try? decoder.decode(ClaudeLine.self, from: line),
                  parsed.isMeta != true, parsed.isSidechain != true,
                  parsed.type == "user" || parsed.type == "assistant",
                  let text = parsed.message?.content?.text,
                  let date = eventDate(parsed.timestamp), DailyStats.dayKey(date, calendar: calendar) == dayKey else { return }
            if project == nil { project = projectName(fromPath: parsed.cwd) }
            append(&messages, role: parsed.type == "user" ? .user : .assistant, text: text, at: date, noise: Self.claudeNoise)
        }
        return messages.isEmpty ? nil : SessionTranscript(provider: "claude", sessionID: sessionID, project: project, messages: messages)
    }

    private func readCodex(_ url: URL, dayKey: String, calendar: Calendar) -> SessionTranscript? {
        guard let sessionID = rolloutSessionID(url.lastPathComponent) else { return nil }
        let decoder = JSONDecoder()
        var messages: [TranscriptMessage] = []
        var project: String?
        var first = true
        forEachLine(in: url) { line in
            if first {
                first = false
                if let meta = try? decoder.decode(CodexLine.self, from: line) { project = projectName(fromPath: meta.payload?.cwd) }
                return
            }
            guard line.range(of: Data("\"message\"".utf8)) != nil,
                  let parsed = try? decoder.decode(CodexLine.self, from: line),
                  parsed.type == "response_item", parsed.payload?.type == "message",
                  let role = parsed.payload?.role, role == "user" || role == "assistant",
                  let date = eventDate(parsed.timestamp), DailyStats.dayKey(date, calendar: calendar) == dayKey else { return }
            let text = (parsed.payload?.content ?? []).filter { $0.type == "input_text" || $0.type == "output_text" }
                .compactMap(\.text).joined(separator: "\n")
            append(&messages, role: role == "user" ? .user : .assistant, text: text, at: date, noise: Self.codexNoise)
        }
        return messages.isEmpty ? nil : SessionTranscript(provider: "codex", sessionID: sessionID, project: project, messages: messages)
    }

    private func append(_ messages: inout [TranscriptMessage], role: TranscriptMessage.Role, text: String,
                        at date: Date, noise: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !noise.contains(where: { trimmed.hasPrefix($0) }) else { return }
        if let last = messages.last, last.role == role, last.text == trimmed { return }
        messages.append(.init(role: role, text: trimmed, at: date))
    }

    /// Calls `body` for each complete line, reading in chunks so very large logs never sit in memory at once.
    private func forEachLine(in url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                body(buffer[start..<newline])
                start = newline + 1
            }
            buffer = Data(buffer[start...])
            if buffer.count > 32 * 1024 * 1024 { buffer = Data() }   // skip one absurdly long line
        }
        if !buffer.isEmpty { body(buffer) }
    }
}
