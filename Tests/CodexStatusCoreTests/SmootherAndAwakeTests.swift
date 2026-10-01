import XCTest
@testable import CodexStatusCore

final class SmootherAndAwakeTests: XCTestCase {
    private func snapshot(running: Int?, appRunning: Bool = true) -> StatusSnapshot {
        StatusSnapshot(sampledAt: Date(), sessions: [], runningCount: running, completedUnreadCount: nil,
                       notice: nil, appIsRunning: appRunning, inspectedWriterCount: 0)
    }

    func testSingleUnknownSampleKeepsLastKnownState() {
        var smoother = SnapshotSmoother()
        XCTAssertEqual(smoother.smooth(snapshot(running: 1)).runningCount, 1)
        XCTAssertEqual(smoother.smooth(snapshot(running: nil)).runningCount, 1)      // flicker hidden
        XCTAssertNil(smoother.smooth(snapshot(running: nil)).runningCount)           // persists -> shown honestly
    }

    func testRecoveryResetsTheStreak() {
        var smoother = SnapshotSmoother()
        _ = smoother.smooth(snapshot(running: 2))
        _ = smoother.smooth(snapshot(running: nil))
        XCTAssertEqual(smoother.smooth(snapshot(running: 0)).runningCount, 0)
        XCTAssertEqual(smoother.smooth(snapshot(running: nil)).runningCount, 0)      // tolerated again
    }

    func testNeverInventsStateOrHidesAppQuitting() {
        var smoother = SnapshotSmoother()
        XCTAssertNil(smoother.smooth(snapshot(running: nil)).runningCount)           // nothing known yet
        _ = smoother.smooth(snapshot(running: 3))
        let closed = smoother.smooth(snapshot(running: nil, appRunning: false))
        XCTAssertFalse(closed.appIsRunning)
        XCTAssertNil(closed.runningCount)
        XCTAssertNil(smoother.smooth(snapshot(running: nil)).runningCount)           // old state was discarded
    }

    func testKeepAwakeRule() {
        XCTAssertTrue(shouldKeepAwake(enabled: true, running: [0, 2]))
        XCTAssertTrue(shouldKeepAwake(enabled: true, running: [nil, 1]))
        XCTAssertFalse(shouldKeepAwake(enabled: true, running: [0, nil]))
        XCTAssertFalse(shouldKeepAwake(enabled: false, running: [5, 5]))
        XCTAssertFalse(shouldKeepAwake(enabled: true, running: []))
    }
}
