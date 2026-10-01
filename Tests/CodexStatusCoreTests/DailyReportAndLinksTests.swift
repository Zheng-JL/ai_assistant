import XCTest
@testable import CodexStatusCore

final class DailyReportAndLinksTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 18))! }

    private func finished(_ id: String, _ title: String, project: String?, seconds: TimeInterval?, hour: Int = 10,
                          provider: String = "claude") -> (StatusEvent, String) {
        let at = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour))!
        return (StatusEvent(kind: .finished, sessionID: id, title: title, project: project, occurredAt: at, duration: seconds), provider)
    }

    private func log(_ items: [(StatusEvent, String)]) -> DailyLog {
        var log = DailyLog(day: "2026-10-01")
        for (event, provider) in items { log.add(event, provider: provider, calendar: calendar) }
        return log
    }

    func testReportGroupsByProjectAndMergesTurnsOfOneSession() {
        let report = makeDailyReport(log: log([
            finished("s1", "修复登录", project: "app", seconds: 120), finished("s1", "修复登录", project: "app", seconds: 180),
            finished("s2", "写文档", project: "docs", seconds: 60, provider: "codex"),
            finished("s3", "杂事", project: nil, seconds: nil)
        ]), tokens: nil, now: now, calendar: calendar)!
        XCTAssertTrue(report.hasPrefix("# 2026-10-01 工作日报"))
        XCTAssertTrue(report.contains("AI 任务完成 4 次，累计 6 分钟，最长一次 3 分钟"))
        XCTAssertTrue(report.contains("- Claude · 修复登录 — 2 次完成，共 5 分钟"))
        XCTAssertTrue(report.contains("- Codex · 写文档 — 1 次完成，共 1 分钟"))
        XCTAssertTrue(report.contains("## 其他"))
        XCTAssertLessThan(report.range(of: "## app")!.lowerBound, report.range(of: "## docs")!.lowerBound)  // longest first
    }

    func testReportIncludesTokensPerProject() {
        let tokens = TokenReport(day: "2026-10-01", contexts: [:], codex: .init(newInput: 1000), claude: .init(output: 2000),
                                 codexProjects: [], claudeProjects: [ProjectTokens(project: "app", totals: .init(output: 2000))])
        let report = makeDailyReport(log: log([finished("s1", "t", project: "app", seconds: 60)]), tokens: tokens,
                                     now: now, calendar: calendar)!
        XCTAssertTrue(report.contains("Codex 1.0K · Claude 2.0K"))
        XCTAssertTrue(report.contains("## app（Token 2.0K）"))
    }

    func testEmptyOrStaleDayGivesNoReport() {
        XCTAssertNil(makeDailyReport(log: DailyLog(day: "2026-10-01"), tokens: nil, now: now, calendar: calendar))
        XCTAssertNil(makeDailyReport(log: log([finished("s", "t", project: nil, seconds: 5)]), tokens: nil,
                                     now: now.addingTimeInterval(86_400), calendar: calendar))
    }

    func testLogRollsOverAndIgnoresNonFinishedAndCaps() {
        var daily = DailyLog(day: "2026-09-30")
        let (event, provider) = finished("s", "t", project: nil, seconds: 1)
        daily.add(event, provider: provider, calendar: calendar)
        XCTAssertEqual(daily.day, "2026-10-01")
        XCTAssertEqual(daily.entries.count, 1)
        daily.add(StatusEvent(kind: .needsInput, sessionID: "s", title: "t", project: nil, occurredAt: now, duration: 1),
                  provider: "claude", calendar: calendar)
        XCTAssertEqual(daily.entries.count, 1)
        for _ in 0..<(DailyLog.limit + 20) { daily.add(event, provider: provider, calendar: calendar) }
        XCTAssertEqual(daily.entries.count, DailyLog.limit)
    }

    func testClaudeSessionLinkOnlyAcceptsTheShapeClaudeAccepts() {
        XCTAssertEqual(claudeSessionURL("local_65532593-ab12")?.absoluteString,
                       "claude://code/continue?session=local_65532593-ab12&source=desktop_action")
        for bad in [nil, "", "8c7da535-5202-4b95-b6fd-78eeb314503b", "local_", "local_a b", "local_a&x=1", "local_a/../b",
                    "local_" + String(repeating: "a", count: 65)] as [String?] {
            XCTAssertNil(claudeSessionURL(bad), bad ?? "nil")
        }
        XCTAssertEqual(claudeNeedsInputURL.host, "code")
    }
}
