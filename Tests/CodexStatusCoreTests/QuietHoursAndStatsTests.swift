import XCTest
@testable import CodexStatusCore

final class QuietHoursAndStatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 30))!
    }

    func testDaytimeWindow() {
        let lunch = QuietHours(startHour: 12, endHour: 14)
        XCTAssertTrue(lunch.contains(date(12), calendar: calendar))
        XCTAssertTrue(lunch.contains(date(13), calendar: calendar))
        XCTAssertFalse(lunch.contains(date(14), calendar: calendar))
        XCTAssertFalse(lunch.contains(date(11), calendar: calendar))
    }

    func testOvernightWindowWrapsPastMidnight() {
        let night = QuietHours(startHour: 22, endHour: 8)
        for hour in [22, 23, 0, 3, 7] { XCTAssertTrue(night.contains(date(hour), calendar: calendar), "\(hour)") }
        for hour in [8, 12, 21] { XCTAssertFalse(night.contains(date(hour), calendar: calendar), "\(hour)") }
        XCTAssertFalse(QuietHours(startHour: 5, endHour: 5).contains(date(5), calendar: calendar))
    }

    private func finished(_ seconds: TimeInterval?, at when: Date) -> StatusEvent {
        .init(kind: .finished, sessionID: "a", title: "t", project: nil, occurredAt: when, duration: seconds)
    }

    func testStatsAccumulateAndRollOverByDay() {
        var stats = DailyStats(day: DailyStats.dayKey(date(9), calendar: calendar))
        stats.add(finished(60, at: date(9)), calendar: calendar)
        stats.add(finished(600, at: date(10)), calendar: calendar)
        stats.add(finished(nil, at: date(11)), calendar: calendar)
        stats.add(.init(kind: .needsInput, sessionID: "a", title: "t", project: nil, occurredAt: date(11), duration: 5),
                  calendar: calendar)
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.totalSeconds, 660)
        XCTAssertEqual(stats.longestSeconds, 600)
        XCTAssertEqual(stats.summary(now: date(12), calendar: calendar), "今日完成 3 个 · 累计 11 分钟 · 最长 10 分钟")
        XCTAssertNil(stats.summary(now: date(12, day: 2), calendar: calendar))
        stats.add(finished(30, at: date(9, day: 2)), calendar: calendar)
        XCTAssertEqual(stats.count, 1)
    }

    func testLongRunningFiresOnceAfterThreshold() {
        var detector = TransitionDetector()
        detector.stuckAfter = 1800
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func running() -> SessionStatus {
            SessionStatus(id: "a", title: "t", phase: .running, isUnread: false, updatedAt: t0, phaseSince: t0)
        }
        XCTAssertTrue(detector.observe([running()], now: t0.addingTimeInterval(1799)).isEmpty)
        let first = detector.observe([running()], now: t0.addingTimeInterval(1800))
        XCTAssertEqual(first.map(\.kind), [.longRunning])
        XCTAssertEqual(first.first?.duration, 1800)
        XCTAssertTrue(detector.observe([running()], now: t0.addingTimeInterval(3600)).isEmpty)
        XCTAssertTrue(first.first!.shouldNotify(minimumDuration: 9999))
    }

    func testLongRunningDisabledByDefaultAndIgnoresWaiting() {
        var off = TransitionDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let long = SessionStatus(id: "a", title: "t", phase: .running, isUnread: false, updatedAt: t0, phaseSince: t0)
        XCTAssertTrue(off.observe([long], now: t0.addingTimeInterval(99_999)).isEmpty)
        var on = TransitionDetector()
        on.stuckAfter = 60
        let waiting = SessionStatus(id: "b", title: "t", phase: .waitingForInput, isUnread: false,
                                    updatedAt: t0, phaseSince: t0)
        XCTAssertTrue(on.observe([waiting], now: t0.addingTimeInterval(9999)).isEmpty)
    }
}
