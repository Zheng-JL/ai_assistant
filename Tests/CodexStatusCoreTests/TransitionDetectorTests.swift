import XCTest
@testable import CodexStatusCore

final class TransitionDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ phase: SessionPhase, since: Date? = nil, updated: Date? = nil,
                         id: String = "a") -> SessionStatus {
        SessionStatus(id: id, title: "任务 \(id)", phase: phase, isUnread: false,
                      updatedAt: updated, phaseSince: since)
    }

    func testFirstSampleNeverNotifies() {
        var detector = TransitionDetector()
        XCTAssertTrue(detector.observe([session(.completed), session(.idle, id: "b")], now: t0).isEmpty)
        XCTAssertTrue(detector.observe([session(.running, since: t0)], now: t0).isEmpty)
    }

    func testRunningToCompletedReportsDuration() {
        var detector = TransitionDetector()
        _ = detector.observe([session(.running, since: t0)], now: t0)
        let end = t0.addingTimeInterval(125)
        let events = detector.observe([session(.completed, updated: end)], now: end.addingTimeInterval(2))
        XCTAssertEqual(events, [.init(kind: .finished, sessionID: "a", title: "任务 a", project: nil,
                                      occurredAt: end, duration: 125)])
        XCTAssertTrue(detector.observe([session(.completed, updated: end)], now: end).isEmpty)
    }

    func testClaudeBusyToIdleFinishes() {
        var detector = TransitionDetector()
        _ = detector.observe([session(.running, since: t0, updated: t0)], now: t0)
        let events = detector.observe([session(.idle, since: t0.addingTimeInterval(30),
                                               updated: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(33))
        XCTAssertEqual(events.map(\.kind), [.finished])
        XCTAssertEqual(events.first?.duration, 30)
    }

    func testNeedsInputFiresOnceAndKeepsOriginalStart() {
        var detector = TransitionDetector()
        _ = detector.observe([session(.running, since: t0)], now: t0)
        let later = t0.addingTimeInterval(60)
        let first = detector.observe([session(.waitingForInput, since: t0)], now: later)
        XCTAssertEqual(first.map(\.kind), [.needsInput])
        XCTAssertEqual(first.first?.duration, 60)
        XCTAssertTrue(detector.observe([session(.waitingForInput, since: t0)], now: later.addingTimeInterval(3)).isEmpty)
        let done = detector.observe([session(.completed, updated: later.addingTimeInterval(90))], now: later.addingTimeInterval(93))
        XCTAssertEqual(done.first?.duration, 150)
    }

    func testInterruptedAndUnknownProduceNoEvent() {
        var detector = TransitionDetector()
        _ = detector.observe([session(.running, since: t0)], now: t0)
        XCTAssertTrue(detector.observe([session(.unknown)], now: t0).isEmpty)
        XCTAssertTrue(detector.observe([session(.interrupted)], now: t0).isEmpty)
        // Interruption cleared tracking, so a later completed state is not a fresh finish.
        XCTAssertTrue(detector.observe([session(.completed)], now: t0).isEmpty)
    }

    func testUnknownSampleDoesNotLoseTrackedRun() {
        var detector = TransitionDetector()
        _ = detector.observe([session(.running, since: t0)], now: t0)
        _ = detector.observe([session(.unknown)], now: t0)
        XCTAssertEqual(detector.observe([session(.completed, updated: t0.addingTimeInterval(10))], now: t0).count, 1)
    }

    func testBackgroundShellKeepsRunTrackedUntilIdle() {
        var detector = TransitionDetector()
        _ = detector.observe([session(.running, since: t0)], now: t0)
        XCTAssertTrue(detector.observe([session(.backgroundRunning, since: t0)], now: t0).isEmpty)
        XCTAssertEqual(detector.observe([session(.idle, updated: t0.addingTimeInterval(40))], now: t0).count, 1)
    }

    func testAgoAndProjectName() {
        XCTAssertEqual(formatAgo(10), "刚刚")
        XCTAssertEqual(formatAgo(300), "5 分钟前")
        XCTAssertEqual(formatAgo(7200), "2 小时前")
        XCTAssertEqual(formatAgo(200_000), "2 天前")
        XCTAssertEqual(projectName(fromPath: "/Users/me/work/my-app"), "my-app")
        XCTAssertEqual(projectName(fromPath: "/Users/me/work/my-app/"), "my-app")
        XCTAssertNil(projectName(fromPath: "/"))
        XCTAssertNil(projectName(fromPath: nil))
        XCTAssertEqual(projectName(fromPath: "/a/" + String(repeating: "x", count: 100))?.count, 40)
    }

    func testEventCarriesProject() {
        var detector = TransitionDetector()
        let running = SessionStatus(id: "a", title: "t", phase: .running, isUnread: false,
                                    updatedAt: t0, phaseSince: t0, project: "proj")
        _ = detector.observe([running], now: t0)
        let done = SessionStatus(id: "a", title: "t", phase: .completed, isUnread: false,
                                 updatedAt: t0.addingTimeInterval(5), project: "proj")
        XCTAssertEqual(detector.observe([done], now: t0).first?.project, "proj")
    }

    func testElapsedFormatting() {
        XCTAssertEqual(formatElapsed(5), "5 秒")
        XCTAssertEqual(formatElapsed(125), "2 分钟")
        XCTAssertEqual(formatElapsed(3600), "1 小时")
        XCTAssertEqual(formatElapsed(3900), "1 小时 5 分")
        XCTAssertEqual(formatElapsed(-3), "0 秒")
    }
}
