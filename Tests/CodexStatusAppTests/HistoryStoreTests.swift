import CodexStatusCore
import XCTest
@testable import CodexStatusApp

final class HistoryStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "history-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func finished(_ id: String, at seconds: TimeInterval) -> StatusEvent {
        .init(kind: .finished, sessionID: id, title: "任务 \(id)", project: "proj",
              occurredAt: Date(timeIntervalSince1970: seconds), duration: 30)
    }

    func testRecordsOnlyFinishedAndKeepsNewestFirst() {
        var store = HistoryStore(defaults: makeDefaults())
        let waiting = StatusEvent(kind: .needsInput, sessionID: "w", title: "w", project: nil,
                                  occurredAt: Date(), duration: nil)
        store.record([waiting, finished("a", at: 100), finished("b", at: 200)], provider: "codex")
        XCTAssertEqual(store.records.map(\.sessionID), ["b", "a"])
    }

    func testSameSessionIsReplacedNotDuplicated() {
        var store = HistoryStore(defaults: makeDefaults())
        store.record([finished("a", at: 100)], provider: "claude")
        store.record([finished("a", at: 300)], provider: "claude")
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.finishedAt, Date(timeIntervalSince1970: 300))
    }

    func testLimitAndPersistenceAndClear() {
        let defaults = makeDefaults()
        var store = HistoryStore(defaults: defaults)
        store.record((0..<12).map { finished("s\($0)", at: Double($0)) }, provider: "codex")
        XCTAssertEqual(store.records.count, HistoryStore.limit)
        XCTAssertEqual(HistoryStore(defaults: defaults).records, store.records)
        store.clear()
        XCTAssertTrue(HistoryStore(defaults: defaults).records.isEmpty)
        XCTAssertTrue(HistoryStore(defaults: defaults).log.entries.isEmpty)
        XCTAssertEqual(HistoryStore(defaults: defaults).stats.count, 0)
    }
}
