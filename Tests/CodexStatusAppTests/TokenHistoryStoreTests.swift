import CodexStatusCore
import XCTest
@testable import CodexStatusApp

final class TokenHistoryStoreTests: XCTestCase {
    func testRecordPersistsAcrossInstances() {
        let name = "token-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var store = TokenHistoryStore(defaults: defaults)
        store.record(TokenReport(day: "2026-10-01", contexts: [:], codex: .init(newInput: 7), claude: .init(),
                                 codexProjects: [], claudeProjects: []))
        XCTAssertEqual(TokenHistoryStore(defaults: defaults).history.days["2026-10-01"]?.codex.newInput, 7)
    }
}
