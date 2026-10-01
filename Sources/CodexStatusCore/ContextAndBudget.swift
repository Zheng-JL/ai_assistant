import Foundation

public struct ContextAlert: Sendable, Equatable {
    public let sessionID: String
    public let title: String
    public let project: String?
    public let fraction: Double
    public var openID: String? = nil
}

/// Warns once when an in-use session's context passes the threshold, and re-arms after it drops
/// well below (for example after the conversation was summarised).
public struct ContextAlertTracker: Sendable {
    private var alerted: Set<String> = []
    private static let rearmMargin = 0.2

    public init() {}

    public mutating func observe(sessions: [SessionStatus], contexts: [String: ContextUsage],
                                 threshold: Double?) -> [ContextAlert] {
        guard let threshold else { return [] }
        var alerts: [ContextAlert] = []
        for session in sessions {
            guard let fraction = contexts[session.id]?.fraction else { continue }
            if fraction < threshold - Self.rearmMargin { alerted.remove(session.id); continue }
            guard fraction >= threshold, !alerted.contains(session.id),
                  session.phase == .running || session.phase == .waitingForInput else { continue }
            alerted.insert(session.id)
            alerts.append(.init(sessionID: session.id, title: session.title, project: session.project, fraction: fraction,
                                 openID: session.openID))
        }
        return alerts
    }
}

/// True once per day when the combined non-cache tokens reach the user's budget.
public func shouldAlertBudget(total: Int, budget: Int?, day: String, alertedDay: String?) -> Bool {
    guard let budget, budget > 0, alertedDay != day else { return false }
    return total >= budget
}

public struct DayTokens: Codable, Equatable, Sendable {
    public var codex: TokenTotals
    public var claude: TokenTotals

    public var withoutCache: Int { codex.withoutCache + claude.withoutCache }
}

/// Per-day token totals kept so the menu can show a short trend.
public struct TokenHistory: Codable, Equatable, Sendable {
    public private(set) var days: [String: DayTokens] = [:]

    public init() {}

    public mutating func record(_ report: TokenReport, keeping limit: Int = 14) {
        guard report.codex.all + report.claude.all > 0 || days[report.day] != nil else { return }
        days[report.day] = DayTokens(codex: report.codex, claude: report.claude)
        for key in days.keys.sorted().dropLast(limit) { days[key] = nil }
    }

    /// Newest first, only days that have data, looking back `count` calendar days from `now`.
    public func recent(_ count: Int, now: Date, calendar: Calendar = .current) -> [(day: String, tokens: DayTokens)] {
        (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = DailyStats.dayKey(date, calendar: calendar)
            return days[key].map { (key, $0) }
        }
    }
}
