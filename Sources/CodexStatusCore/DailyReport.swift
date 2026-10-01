import Foundation

public struct DailyLogEntry: Codable, Equatable, Sendable {
    public let provider: String   // "codex" | "claude"
    public let sessionID: String
    public let title: String
    public let project: String?
    public let finishedAt: Date
    public let duration: TimeInterval?
}

/// Every finished task of one day, kept so a report can be written at any time.
public struct DailyLog: Codable, Equatable, Sendable {
    public private(set) var day: String
    public private(set) var entries: [DailyLogEntry] = []
    public static let limit = 300

    public init(day: String) { self.day = day }

    public mutating func add(_ event: StatusEvent, provider: String, calendar: Calendar = .current) {
        guard event.kind == .finished else { return }
        let key = DailyStats.dayKey(event.occurredAt, calendar: calendar)
        if key != day { self = DailyLog(day: key) }
        entries.append(.init(provider: provider, sessionID: event.sessionID, title: event.title,
                             project: event.project, finishedAt: event.occurredAt, duration: event.duration))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}

/// A plain-text work log for the day, grouped by project. Nil when there is nothing to report.
public func makeDailyReport(log: DailyLog, tokens: TokenReport?, now: Date, calendar: Calendar = .current) -> String? {
    let today = DailyStats.dayKey(now, calendar: calendar)
    let entries = log.day == today ? log.entries : []
    let hasTokens = (tokens?.day == today) && ((tokens?.codex.all ?? 0) + (tokens?.claude.all ?? 0) > 0)
    guard !entries.isEmpty || hasTokens else { return nil }

    var lines = ["# \(today) 工作日报"]
    if !entries.isEmpty {
        let total = entries.compactMap(\.duration).reduce(0, +)
        let longest = entries.compactMap(\.duration).max() ?? 0
        var summary = "- AI 任务完成 \(entries.count) 次"
        if total >= 1 { summary += "，累计 \(formatElapsed(total))，最长一次 \(formatElapsed(longest))" }
        lines.append(summary)
    }
    if let tokens, hasTokens {
        lines.append("- Token（新输入+输出，不含缓存）：Codex \(formatTokens(tokens.codex.withoutCache)) · Claude \(formatTokens(tokens.claude.withoutCache))")
    }

    var projectTokens: [String: Int] = [:]
    for item in (tokens?.codexProjects ?? []) + (tokens?.claudeProjects ?? []) {
        projectTokens[item.project, default: 0] += item.totals.withoutCache
    }
    let byProject = Dictionary(grouping: entries, by: { $0.project ?? "其他" })
    func spent(_ group: [DailyLogEntry]) -> TimeInterval { group.compactMap(\.duration).reduce(0, +) }
    for (project, group) in byProject.sorted(by: { spent($0.value) == spent($1.value) ? $0.key < $1.key : spent($0.value) > spent($1.value) }) {
        lines.append("")
        lines.append("## \(project)" + (projectTokens[project].map { "（Token \(formatTokens($0))）" } ?? ""))
        // One line per session: a long conversation finishes many times a day.
        let bySession = Dictionary(grouping: group, by: { "\($0.provider)|\($0.sessionID)" })
        let rows = bySession.values.map { rowEntries -> (String, TimeInterval) in
            let latest = rowEntries.max { $0.finishedAt < $1.finishedAt }!
            let name = latest.provider == "codex" ? "Codex" : "Claude"
            var text = "- \(name) · \(latest.title)"
            let duration = spent(rowEntries)
            text += rowEntries.count > 1 ? " — \(rowEntries.count) 次完成" : " — 1 次完成"
            if duration >= 1 { text += "，共 \(formatElapsed(duration))" }
            return (text, duration)
        }
        for row in rows.sorted(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }).prefix(15) { lines.append(row.0) }
        if rows.count > 15 { lines.append("- 其余 \(rows.count - 15) 个会话略") }
    }
    return lines.joined(separator: "\n")
}
