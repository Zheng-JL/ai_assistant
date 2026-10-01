import XCTest
@testable import CodexStatusCore

final class ContextAndBudgetTests: XCTestCase {
    private func session(_ id: String, _ phase: SessionPhase = .running) -> SessionStatus {
        SessionStatus(id: id, title: "t\(id)", phase: phase, isUnread: false, updatedAt: nil)
    }
    private func context(_ fraction: Double) -> ContextUsage { .init(used: Int(fraction * 1000), window: 1000) }

    func testFractionNeedsAWindowAndIsCapped() {
        XCTAssertEqual(ContextUsage(used: 250, window: 1000).fraction, 0.25)
        XCTAssertNil(ContextUsage(used: 250, window: nil).fraction)
        XCTAssertEqual(ContextUsage(used: 5000, window: 1000).fraction, 1)
    }

    func testAlertsOnceThenRearmsAfterDroppingWellBelow() {
        var tracker = ContextAlertTracker()
        XCTAssertTrue(tracker.observe(sessions: [session("a")], contexts: ["a": context(0.7)], threshold: 0.8).isEmpty)
        XCTAssertEqual(tracker.observe(sessions: [session("a")], contexts: ["a": context(0.85)], threshold: 0.8).count, 1)
        XCTAssertTrue(tracker.observe(sessions: [session("a")], contexts: ["a": context(0.9)], threshold: 0.8).isEmpty)
        XCTAssertTrue(tracker.observe(sessions: [session("a")], contexts: ["a": context(0.7)], threshold: 0.8).isEmpty)  // inside margin
        XCTAssertTrue(tracker.observe(sessions: [session("a")], contexts: ["a": context(0.9)], threshold: 0.8).isEmpty)
        _ = tracker.observe(sessions: [session("a")], contexts: ["a": context(0.3)], threshold: 0.8)                    // summarised
        XCTAssertEqual(tracker.observe(sessions: [session("a")], contexts: ["a": context(0.9)], threshold: 0.8).count, 1)
    }

    func testOnlyInUseSessionsWithKnownWindowAlert() {
        var tracker = ContextAlertTracker()
        let contexts = ["idle": context(0.95), "claude": ContextUsage(used: 900_000, window: nil), "run": context(0.95)]
        let alerts = tracker.observe(sessions: [session("idle", .idle), session("claude"), session("run", .waitingForInput)],
                                     contexts: contexts, threshold: 0.8)
        XCTAssertEqual(alerts.map(\.sessionID), ["run"])
        XCTAssertTrue(tracker.observe(sessions: [session("run")], contexts: contexts, threshold: nil).isEmpty)
    }

    func testBudgetAlertsOncePerDay() {
        XCTAssertFalse(shouldAlertBudget(total: 999, budget: 1000, day: "d", alertedDay: nil))
        XCTAssertTrue(shouldAlertBudget(total: 1000, budget: 1000, day: "d", alertedDay: nil))
        XCTAssertFalse(shouldAlertBudget(total: 5000, budget: 1000, day: "d", alertedDay: "d"))
        XCTAssertTrue(shouldAlertBudget(total: 5000, budget: 1000, day: "d2", alertedDay: "d"))
        XCTAssertFalse(shouldAlertBudget(total: 5000, budget: 0, day: "d", alertedDay: nil))
        XCTAssertFalse(shouldAlertBudget(total: 5000, budget: nil, day: "d", alertedDay: nil))
    }

    private func report(_ day: String, codex: Int, claude: Int) -> TokenReport {
        TokenReport(day: day, contexts: [:], codex: .init(newInput: codex), claude: .init(output: claude),
                    codexProjects: [], claudeProjects: [])
    }

    func testHistoryKeepsRecentDaysAndReturnsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        var history = TokenHistory()
        for day in 1...10 { history.record(report(String(format: "2026-10-%02d", day), codex: day * 10, claude: 1), keeping: 7) }
        XCTAssertEqual(history.days.count, 7)
        let recent = history.recent(7, now: now, calendar: calendar)
        XCTAssertEqual(recent.map(\.day).first, "2026-10-10")
        XCTAssertEqual(recent.count, 7)
        XCTAssertEqual(recent.first?.tokens.withoutCache, 101)
        history.record(report("2026-10-10", codex: 500, claude: 1), keeping: 7)
        XCTAssertEqual(history.recent(1, now: now, calendar: calendar).first?.tokens.codex.newInput, 500)
    }

    func testHistoryIgnoresEmptyDaysAndRoundTrips() throws {
        var history = TokenHistory()
        history.record(report("2026-10-01", codex: 0, claude: 0))
        XCTAssertTrue(history.days.isEmpty)
        history.record(report("2026-10-01", codex: 5, claude: 0))
        let decoded = try JSONDecoder().decode(TokenHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    func testRolloutSessionIDFromFileName() {
        XCTAssertEqual(rolloutSessionID("rollout-2026-10-01T09-00-00-019DA1C2-0000-7000-8000-ABCDEF012345.jsonl"),
                       "019da1c2-0000-7000-8000-abcdef012345")
        XCTAssertNil(rolloutSessionID("notes.jsonl"))
    }
}
