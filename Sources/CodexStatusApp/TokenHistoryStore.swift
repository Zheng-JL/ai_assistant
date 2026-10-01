import CodexStatusCore
import Foundation

/// Persists the per-day token totals so the menu can show a week-long trend across restarts.
struct TokenHistoryStore {
    private static let key = "tokenHistory"
    private(set) var history: TokenHistory
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(TokenHistory.self, from: $0) })
            ?? TokenHistory()
    }

    mutating func record(_ report: TokenReport) {
        let before = history
        history.record(report)
        guard history != before, let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
