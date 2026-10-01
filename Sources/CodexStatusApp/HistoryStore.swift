import CodexStatusCore
import Foundation

struct FinishedRecord: Codable, Equatable {
    var provider: String   // "codex" | "claude"
    var sessionID: String
    var title: String
    var project: String?
    var finishedAt: Date
    var duration: TimeInterval?
    var openID: String?    // Claude's `local_…` ID, used to jump to the session
}

/// Keeps the last few finished tasks across restarts. Stores only the title shown in the menu,
/// the project folder name and timings — never message content or full paths.
struct HistoryStore {
    private static let key = "recentFinished"
    static let limit = 8
    private static let statsKey = "dailyStats"
    private static let logKey = "dailyLog"
    private(set) var records: [FinishedRecord]
    private(set) var stats: DailyStats
    private(set) var log: DailyLog
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = (defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([FinishedRecord].self, from: $0) }) ?? []
        stats = (defaults.data(forKey: Self.statsKey)
            .flatMap { try? JSONDecoder().decode(DailyStats.self, from: $0) }) ?? DailyStats(day: "")
        log = (defaults.data(forKey: Self.logKey)
            .flatMap { try? JSONDecoder().decode(DailyLog.self, from: $0) }) ?? DailyLog(day: "")
    }

    mutating func record(_ events: [StatusEvent], provider: String) {
        let finished = events.filter { $0.kind == .finished }
        guard !finished.isEmpty else { return }
        for event in finished {
            stats.add(event)
            log.add(event, provider: provider)
            records.removeAll { $0.provider == provider && $0.sessionID == event.sessionID }
            records.insert(.init(provider: provider, sessionID: event.sessionID, title: event.title,
                                 project: event.project, finishedAt: event.occurredAt,
                                 duration: event.duration, openID: event.openID), at: 0)
        }
        records = Array(records.sorted { $0.finishedAt > $1.finishedAt }.prefix(Self.limit))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.key) }
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: Self.statsKey) }
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Self.logKey) }
    }

    /// Forgets everything stored about finished tasks: the recent list, today's log (which also holds
    /// task titles) and today's counters.
    mutating func clear() {
        records = []
        stats = DailyStats(day: "")
        log = DailyLog(day: "")
        for key in [Self.key, Self.statsKey, Self.logKey] { defaults.removeObject(forKey: key) }
    }
}
