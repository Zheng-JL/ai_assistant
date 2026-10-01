import Darwin
import Foundation

public struct TokenTotals: Sendable, Equatable, Codable {
    public var newInput = 0
    public var cached = 0
    public var output = 0

    public init(newInput: Int = 0, cached: Int = 0, output: Int = 0) {
        self.newInput = newInput
        self.cached = cached
        self.output = output
    }

    /// New input plus output: the headline number, deliberately excluding cache hits.
    public var withoutCache: Int { newInput + output }
    public var all: Int { newInput + cached + output }

    public static func += (left: inout TokenTotals, right: TokenTotals) {
        left.newInput += right.newInput
        left.cached += right.cached
        left.output += right.output
    }
}

public struct ProjectTokens: Sendable, Equatable {
    public let project: String
    public let totals: TokenTotals
}

/// How much of a session's context window the latest request used.
public struct ContextUsage: Sendable, Equatable {
    public let used: Int
    /// nil when the log does not state the window (Claude).
    public let window: Int?
    public var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}

public struct TokenReport: Sendable, Equatable {
    public let day: String
    /// Latest context usage per session ID, for sessions whose log file changed today.
    public let contexts: [String: ContextUsage]
    public let codex: TokenTotals
    public let claude: TokenTotals
    public let codexProjects: [ProjectTokens]
    public let claudeProjects: [ProjectTokens]

    public init(day: String, contexts: [String: ContextUsage], codex: TokenTotals, claude: TokenTotals,
                codexProjects: [ProjectTokens], claudeProjects: [ProjectTokens]) {
        self.day = day; self.contexts = contexts; self.codex = codex; self.claude = claude
        self.codexProjects = codexProjects; self.claudeProjects = claudeProjects
    }
}

public func formatTokens(_ count: Int) -> String {
    let value = Double(max(0, count))
    if value < 1_000 { return String(Int(value)) }
    if value < 999_950 { return String(format: "%.1fK", value / 1_000) }
    if value < 999_950_000 { return String(format: "%.1fM", value / 1_000_000) }
    return String(format: "%.2fB", value / 1_000_000_000)
}

private struct RawUsage {
    var input = 0
    var cached = 0
    var output = 0
}

private struct CodexFileState {
    var sessionID: String?
    var context: ContextUsage?
    var offset: UInt64 = 0
    var fileNumber: UInt64 = 0
    var checkedHeader = false
    var project: String?
    var last: RawUsage?
    var today = TokenTotals()
}

private struct ClaudeFileState {
    var sessionID: String?
    var context: ContextUsage?
    var contextAt = Date.distantPast
    var offset: UInt64 = 0
    var fileNumber: UInt64 = 0
    var project: String?
}

private struct ClaudeMessage {
    var totals: TokenTotals
    var project: String?
}

// Whitelists: only timestamps, the working directory and token counters are decoded.
// Message text, tool input and tool output are never read into these types.
private struct CodexMeta: Decodable {
    struct Payload: Decodable { let cwd: String? }
    let payload: Payload?
}

private struct CodexTokenLine: Decodable {
    struct Usage: Decodable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?
    }
    struct Info: Decodable {
        let total_token_usage: Usage?
        let last_token_usage: Usage?
        let model_context_window: Int?
    }
    struct Payload: Decodable {
        let type: String?
        let info: Info?
    }
    let timestamp: String?
    let payload: Payload?
}

private struct ClaudeLine: Decodable {
    struct Usage: Decodable {
        let input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens: Int?
    }
    struct Message: Decodable {
        let id: String?
        let usage: Usage?
    }
    let isSidechain: Bool?
    let timestamp: String?
    let cwd: String?
    let message: Message?
}

private enum ReadResult {
    case skipped
    case anomaly
    case read(consumed: UInt64, fileNumber: UInt64)
}

/// Counts today's tokens from the local Codex and Claude Code session logs.
/// Only files modified today are followed, each is read incrementally from the last complete line,
/// and only lines that carry token counters are decoded.
public actor TokenUsageSource {
    private static let enumerationInterval: TimeInterval = 10
    private static let chunkSize = 4 * 1024 * 1024
    private static let maxLine = 16 * 1024 * 1024
    private static let tokenCountMarker = Data("token_count".utf8)
    private static let totalMarker = Data("total_token_usage".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)

    private let codexRoot: URL
    private let claudeRoot: URL
    private let decoder = JSONDecoder()
    private var day = ""
    private var codexFiles: [URL: CodexFileState] = [:]
    private var claudeFiles: [URL: ClaudeFileState] = [:]
    private var claudeMessages: [String: ClaudeMessage] = [:]
    private var lastEnumeration = Date.distantPast

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexRoot = home.appendingPathComponent(".codex/sessions").resolvingSymlinksInPath().standardizedFileURL
        claudeRoot = home.appendingPathComponent(".claude/projects").resolvingSymlinksInPath().standardizedFileURL
    }

    public func sample(now: Date = Date()) -> TokenReport {
        let calendar = Calendar.current
        let key = DailyStats.dayKey(now, calendar: calendar)
        if key != day { reset(); day = key }
        if !pass(now: now, key: key, calendar: calendar, force: false) {
            // A file was replaced or truncated: recount from scratch rather than risk drift.
            reset()
            day = key
            _ = pass(now: now, key: key, calendar: calendar, force: true)
        }
        return report(key)
    }

    private func reset() {
        codexFiles = [:]
        claudeFiles = [:]
        claudeMessages = [:]
        lastEnumeration = .distantPast
    }

    private func pass(now: Date, key: String, calendar: Calendar, force: Bool) -> Bool {
        if force || now.timeIntervalSince(lastEnumeration) >= Self.enumerationInterval {
            enumerate(since: calendar.startOfDay(for: now))
            lastEnumeration = now
        }
        for url in Array(codexFiles.keys) {
            guard var state = codexFiles[url] else { continue }
            let result = readNew(url: url, offset: state.offset, expected: state.fileNumber) { line in
                handleCodex(line, &state, key: key, calendar: calendar)
            }
            switch result {
            case .anomaly: return false
            case .skipped: break
            case .read(let consumed, let number):
                state.offset += consumed
                state.fileNumber = number
                codexFiles[url] = state
            }
        }
        for url in Array(claudeFiles.keys) {
            guard var state = claudeFiles[url] else { continue }
            let result = readNew(url: url, offset: state.offset, expected: state.fileNumber) { line in
                handleClaude(line, &state, key: key, calendar: calendar)
            }
            switch result {
            case .anomaly: return false
            case .skipped: break
            case .read(let consumed, let number):
                state.offset += consumed
                state.fileNumber = number
                claudeFiles[url] = state
            }
        }
        return true
    }

    private func enumerate(since start: Date) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for (root, isCodex) in [(codexRoot, true), (claudeRoot, false)] {
            guard FileManager.default.fileExists(atPath: root.path),
                  let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, url.pathExtension == "jsonl",
                      let modified = values.contentModificationDate, modified >= start else { continue }
                let file = url.standardizedFileURL
                if isCodex {
                    guard file.lastPathComponent.hasPrefix("rollout-") else { continue }
                    if codexFiles[file] == nil {
                        codexFiles[file] = CodexFileState(sessionID: rolloutSessionID(file.lastPathComponent))
                    }
                } else if claudeFiles[file] == nil {
                    claudeFiles[file] = ClaudeFileState(
                        sessionID: normalizedID(file.deletingPathExtension().lastPathComponent))
                }
            }
        }
    }

    /// Feeds each complete new line to `body`. A trailing partial line is left for the next call.
    private func readNew(url: URL, offset: UInt64, expected: UInt64, body: (Data) -> Void) -> ReadResult {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return .skipped }
        if (expected != 0 && number != expected) || size < offset { return .anomaly }
        if size == offset { return .read(consumed: 0, fileNumber: number) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .skipped }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return .skipped }
        var buffer = Data()
        var consumed: UInt64 = 0
        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                body(buffer[start..<newline])
                start = newline + 1
            }
            consumed += UInt64(start - buffer.startIndex)
            buffer = Data(buffer[start...])
            if buffer.count > Self.maxLine {
                consumed += UInt64(buffer.count)  // skip an absurdly long line instead of buffering it
                buffer = Data()
            }
        }
        return .read(consumed: consumed, fileNumber: number)
    }

    private func handleCodex(_ line: Data, _ state: inout CodexFileState, key: String, calendar: Calendar) {
        if !state.checkedHeader {
            state.checkedHeader = true
            if let meta = try? decoder.decode(CodexMeta.self, from: line) {
                state.project = projectName(fromPath: meta.payload?.cwd)
            }
            return
        }
        guard line.range(of: Self.tokenCountMarker) != nil, line.range(of: Self.totalMarker) != nil,
              let parsed = try? decoder.decode(CodexTokenLine.self, from: line),
              parsed.payload?.type == "token_count",
              let total = parsed.payload?.info?.total_token_usage else { return }
        if let last = parsed.payload?.info?.last_token_usage, let window = parsed.payload?.info?.model_context_window,
           window > 0 {
            let used = last.total_tokens ?? ((last.input_tokens ?? 0) + (last.output_tokens ?? 0))
            state.context = ContextUsage(used: used, window: window)
        }
        let now = RawUsage(input: total.input_tokens ?? 0, cached: total.cached_input_tokens ?? 0,
                           output: total.output_tokens ?? 0)
        // Totals are cumulative per session: count only the growth, so repeated events add nothing.
        var delta = now
        if let last = state.last, now.input >= last.input, now.cached >= last.cached, now.output >= last.output {
            delta = RawUsage(input: now.input - last.input, cached: now.cached - last.cached,
                             output: now.output - last.output)
        }
        state.last = now
        guard let date = eventDate(parsed.timestamp), DailyStats.dayKey(date, calendar: calendar) == key else { return }
        // Cached tokens are a subset of the reported input tokens.
        state.today += TokenTotals(newInput: max(0, delta.input - delta.cached), cached: delta.cached,
                                   output: delta.output)
    }

    private func handleClaude(_ line: Data, _ state: inout ClaudeFileState, key: String, calendar: Calendar) {
        guard line.range(of: Self.usageMarker) != nil,
              let parsed = try? decoder.decode(ClaudeLine.self, from: line),
              let usage = parsed.message?.usage, let id = parsed.message?.id, !id.isEmpty,
              let date = eventDate(parsed.timestamp) else { return }
        // Context size = everything the latest main-thread request sent (sub-agent traffic is separate).
        if parsed.isSidechain != true, date >= state.contextAt {
            let used = (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)
                + (usage.cache_read_input_tokens ?? 0)
            if used > 0 {
                state.context = ContextUsage(used: used, window: nil)
                state.contextAt = date
            }
        }
        guard DailyStats.dayKey(date, calendar: calendar) == key else { return }
        if state.project == nil { state.project = projectName(fromPath: parsed.cwd) }
        let totals = TokenTotals(
            newInput: (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0),
            cached: usage.cache_read_input_tokens ?? 0, output: usage.output_tokens ?? 0)
        // One reply is logged once per content block with the same id; keep the largest reading.
        if let existing = claudeMessages[id], existing.totals.all >= totals.all { return }
        claudeMessages[id] = ClaudeMessage(totals: totals, project: state.project)
    }

    private func report(_ key: String) -> TokenReport {
        var codex = TokenTotals()
        var codexByProject: [String: TokenTotals] = [:]
        for state in codexFiles.values {
            codex += state.today
            codexByProject[state.project ?? "其他", default: TokenTotals()] += state.today
        }
        var claude = TokenTotals()
        var claudeByProject: [String: TokenTotals] = [:]
        for message in claudeMessages.values {
            claude += message.totals
            claudeByProject[message.project ?? "其他", default: TokenTotals()] += message.totals
        }
        func top(_ groups: [String: TokenTotals]) -> [ProjectTokens] {
            groups.filter { $0.value.all > 0 }
                .sorted { $0.value.withoutCache == $1.value.withoutCache
                    ? $0.key < $1.key : $0.value.withoutCache > $1.value.withoutCache }
                .prefix(5).map { ProjectTokens(project: $0.key, totals: $0.value) }
        }
        var contexts: [String: ContextUsage] = [:]
        for state in codexFiles.values { if let id = state.sessionID, let context = state.context { contexts[id] = context } }
        for state in claudeFiles.values { if let id = state.sessionID, let context = state.context { contexts[id] = context } }
        return TokenReport(day: key, contexts: contexts, codex: codex, claude: claude,
                           codexProjects: top(codexByProject), claudeProjects: top(claudeByProject))
    }
}

/// Session ID embedded in a Codex rollout file name, normalised to lower case.
func rolloutSessionID(_ fileName: String) -> String? {
    guard let range = fileName.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
                                     options: .regularExpression) else { return nil }
    return normalizedID(String(fileName[range]))
}
