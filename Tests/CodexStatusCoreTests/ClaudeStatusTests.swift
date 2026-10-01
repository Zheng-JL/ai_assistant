import Foundation
import XCTest
@testable import CodexStatusCore

final class ClaudeStatusTests: XCTestCase {
    private let id = "3ff91765-8fdc-4ed7-bda1-dfa6e5e1c6d1"
    private let now = Date(timeIntervalSince1970: 1_790_740_000)
    private var started: Date { now.addingTimeInterval(-120) }

    func testBusyDesktopSessionIsRunning() async throws {
        let result = try await sample(status: "busy")
        XCTAssertEqual(result.runningCount, 1)
        XCTAssertEqual(result.sessions.first?.phase, .running)
        XCTAssertNil(result.completedUnreadCount)
        XCTAssertEqual(result.inspectedEngineCount, 1)
        XCTAssertEqual(result.inspectedWriterCount, 0)
    }

    func testIdleNeverMeansCompletedOrUnread() async throws {
        let result = try await sample(status: "idle")
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertEqual(result.sessions.first?.phase, .idle)
        XCTAssertEqual(result.sessions.first?.isUnread, false)
        XCTAssertNil(result.completedUnreadCount)
    }

    func testWaitingIsNotCountedAsRunning() async throws {
        let result = try await sample(status: "waiting")
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertEqual(result.sessions.first?.phase, .waitingForInput)
    }

    func testBackgroundShellIsSeparateFromMainTurn() async throws {
        let result = try await sample(status: "shell")
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertEqual(result.sessions.first?.phase, .backgroundRunning)
    }

    func testUnknownStatusDoesNotPretendZero() async throws {
        let result = try await sample(status: "new-state")
        XCTAssertNil(result.runningCount)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testMissingStatusIsUnknown() async throws {
        let result = try await sample(overrides: ["status": NSNull()])
        XCTAssertNil(result.runningCount)
    }

    func testNewerVersionStillCountsButWarns() async throws {
        let result = try await sample(overrides: ["version": "2.1.285"])
        XCTAssertEqual(result.runningCount, 1)
        XCTAssertTrue(result.notice?.contains("2.1.285") == true)
    }

    func testVerifiedVersionHasNoNotice() async throws {
        let result = try await sample()
        XCTAssertNil(result.notice)
    }

    func testGarbageVersionIsUnknown() async throws {
        let result = try await sample(overrides: ["version": "banana"])
        XCTAssertNil(result.runningCount)
    }

    func testNewVersionWithNewStatusWordStillDegradesToUnknown() async throws {
        let result = try await sample(status: "new-state", overrides: ["version": "3.0.0"])
        XCTAssertNil(result.runningCount)
        XCTAssertTrue(result.notice?.contains("3.0.0") == true)
    }

    func testHostSessionIDBecomesOpenIDOnlyWhenClaudeWouldAcceptIt() async throws {
        let valid = try await sample(overrides: ["hostSessionId": "local_65532593-aa11"])
        XCTAssertEqual(valid.sessions.first?.openID, "local_65532593-aa11")
        for bad: Any in ["not-local", "local_a b", NSNull(), 42] {
            let result = try await sample(overrides: ["hostSessionId": bad])
            XCTAssertNil(result.sessions.first?.openID)
            XCTAssertEqual(result.runningCount, 1)          // a bad link ID must not hide the session
        }
    }

    func testOtherEntrypointIsNotCounted() async throws {
        let result = try await sample(overrides: ["entrypoint": "cli"])
        XCTAssertNil(result.runningCount)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testUnknownKindIsNotCounted() async throws {
        let result = try await sample(overrides: ["kind": "new-kind"])
        XCTAssertNil(result.runningCount)
    }

    func testUnverifiedAgentMarkerDoesNotPretendZero() async throws {
        let result = try await sample(overrides: ["agent": ["synthetic": true]])
        XCTAssertNil(result.runningCount)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testSpareEngineIsExcluded() async throws {
        let result = try await sample(overrides: ["spare": true])
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testRegistryPIDMustMatchLiveEngine() async throws {
        let result = try await sample(overrides: ["pid": 42])
        XCTAssertNil(result.runningCount)
    }

    func testRestartedProcessDoesNotResurrectOldBusySession() async throws {
        let result = try await sample(overrides: ["procStart": processStart(started.addingTimeInterval(-60))])
        XCTAssertNil(result.runningCount)
    }

    func testMalformedProcessStartIsUnknown() async throws {
        let result = try await sample(overrides: ["procStart": "invalid"])
        XCTAssertNil(result.runningCount)
    }

    func testRegistryProcessStartIsUTC() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let result = try await sample(overrides: ["procStart": formatter.string(from: started)])
        XCTAssertEqual(result.runningCount, 1)
    }

    func testStartedTimestampBeforeEngineIsUnknown() async throws {
        let result = try await sample(overrides: ["startedAt": started.addingTimeInterval(-60).timeIntervalSince1970 * 1000])
        XCTAssertNil(result.runningCount)
    }

    func testFutureTimestampIsUnknown() async throws {
        let result = try await sample(overrides: ["statusUpdatedAt": now.addingTimeInterval(60).timeIntervalSince1970 * 1000])
        XCTAssertNil(result.runningCount)
    }

    func testStatusOlderThanRegistrationIsUnknown() async throws {
        let result = try await sample(overrides: ["statusUpdatedAt": started.timeIntervalSince1970 * 1000])
        XCTAssertNil(result.runningCount)
    }

    func testInvalidSessionIDIsUnknown() async throws {
        let result = try await sample(overrides: ["sessionId": "invalid"])
        XCTAssertNil(result.runningCount)
    }

    func testDuplicateHolderCountsOnce() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11)
        try write(root, pid: 12)
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11), engine(12)])
        XCTAssertEqual(result.runningCount, 1)
        XCTAssertEqual(result.sessions.count, 1)
    }

    func testDisagreeingHoldersAreUnknown() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11, status: "idle")
        try write(root, pid: 12)
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11), engine(12)])
        XCTAssertNil(result.runningCount)
        XCTAssertEqual(result.sessions.first?.phase, .unknown)
    }

    func testMoreThanFiftyRunningSessions() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        var engines: [ClaudeEngineRecord] = []
        for pid: Int32 in 11..<86 {
            try write(root, pid: pid, overrides: ["sessionId": UUID().uuidString])
            engines.append(engine(pid))
        }
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: engines)
        XCTAssertEqual(result.runningCount, 75)
        XCTAssertEqual(result.sessions.count, 75)
    }

    func testOnlyLiveEngineRegistryFilesAreRead() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11, status: "idle")
        try Data("damaged stale registration".utf8).write(to: registry(root, pid: 12))
        try Data("unrelated".utf8).write(to: root.appendingPathComponent(".claude/sessions/settings.json"))
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertEqual(result.sessions.count, 1)
    }

    func testNoEnginesIsZeroRunningButNotZeroUnread() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11)
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [])
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertNil(result.completedUnreadCount)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testMissingLiveRegistryIsUnknown() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testDamagedOrPartialJSONIsUnknown() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"pid":11,"status":"busy""#.utf8).write(to: registry(root, pid: 11))
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testOversizedRegistryIsUnknown() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 32, count: 64 * 1024 + 1).write(to: registry(root, pid: 11))
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testSymlinkedRegistryIsRejected() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 12)
        try FileManager.default.createSymbolicLink(at: registry(root, pid: 11), withDestinationURL: registry(root, pid: 12))
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testSymlinkedSessionDirectoryIsRejected() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11)
        let sessions = root.appendingPathComponent(".claude/sessions")
        let moved = root.appendingPathComponent("moved-sessions")
        try FileManager.default.moveItem(at: sessions, to: moved)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: moved)
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testSymlinkedClaudeDirectoryIsRejected() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11)
        let directory = root.appendingPathComponent(".claude")
        let moved = root.appendingPathComponent("moved-claude")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testNonRegularRegistrationIsRejected() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: registry(root, pid: 11), withIntermediateDirectories: false)
        let result = await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
        XCTAssertNil(result.runningCount)
    }

    func testBadTitleDoesNotBreakCounts() async throws {
        let result = try await sample(overrides: ["name": ["not": "a title"]])
        XCTAssertEqual(result.runningCount, 1)
        XCTAssertEqual(result.sessions.first?.title, "Claude Code \(id.prefix(8))")
    }

    func testTitleControlsAreRemovedAndLengthIsBounded() async throws {
        let result = try await sample(overrides: ["name": "\n" + String(repeating: "x", count: 400)])
        XCTAssertEqual(result.sessions.first?.title.count, 256)
        XCTAssertFalse(result.sessions.first?.title.contains("\n") ?? true)
    }

    func testUnrelatedFieldsDoNotAffectCounts() async throws {
        let result = try await sample(overrides: ["message": ["synthetic": []], "peerFeatures": 42,
                                                "messagingSocketPath": ["synthetic": true]])
        XCTAssertEqual(result.runningCount, 1)
    }

    func testStatusChangesWithoutProcessRestartAreObserved() async throws {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ClaudeStatusSource(home: root)
        try write(root, pid: 11)
        let first = await source.assemble(now: now, engines: [engine(11)])
        XCTAssertEqual(first.runningCount, 1)
        try write(root, pid: 11, status: "idle")
        let second = await source.assemble(now: now, engines: [engine(11)])
        XCTAssertEqual(second.runningCount, 0)
        XCTAssertNil(second.completedUnreadCount)
    }

    func testClaudeNotRunningIsUnknown() async {
        let result = await ClaudeStatusSource().sample(appPID: nil, appBundle: nil)
        XCTAssertFalse(result.appIsRunning)
        XCTAssertNil(result.runningCount)
    }

    func testUnverifiedBundleIsUnknown() async {
        let result = await ClaudeStatusSource().sample(appPID: 11, appBundle: nil)
        XCTAssertTrue(result.appIsRunning)
        XCTAssertNil(result.runningCount)
    }

    private func sample(status: String = "busy", overrides: [String: Any] = [:]) async throws -> StatusSnapshot {
        let root = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, pid: 11, status: status, overrides: overrides)
        return await ClaudeStatusSource(home: root).assemble(now: now, engines: [engine(11)])
    }

    private func write(_ root: URL, pid: Int32, status: String = "busy",
                       overrides: [String: Any] = [:]) throws {
        var object: [String: Any] = [
            "pid": pid, "procStart": processStart(started), "version": "2.1.284",
            "entrypoint": "claude-desktop", "kind": "interactive", "sessionId": id,
            "startedAt": started.addingTimeInterval(1).timeIntervalSince1970 * 1000,
            "status": status, "statusUpdatedAt": now.timeIntervalSince1970 * 1000,
            "name": "Synthetic Code session"
        ]
        object.merge(overrides) { _, new in new }
        try JSONSerialization.data(withJSONObject: object).write(to: registry(root, pid: pid))
    }

    private func engine(_ pid: Int32) -> ClaudeEngineRecord { .init(pid: pid, startedAt: started) }

    private func processStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func registry(_ root: URL, pid: Int32) -> URL {
        root.appendingPathComponent(".claude/sessions/\(pid).json")
    }

    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-status-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/sessions"),
                                               withIntermediateDirectories: true)
        return root
    }
}

import ProcessInspection

final class ClaudeEnginePathTests: XCTestCase {
    private let directory = "/Users/me/Library/Application Support/Claude/claude-code"

    private func accepts(_ path: String) -> Bool { cs_is_claude_engine_path(path, directory) == 1 }

    func testAnyNumericEngineVersionIsAccepted() {
        for version in ["2.1.284", "2.1.285", "2.2.0", "10.20.300", "3.0.1"] {
            XCTAssertTrue(accepts("\(directory)/\(version)/claude.app/Contents/MacOS/claude"), version)
        }
    }

    func testStructureIsStillCheckedStrictly() {
        for path in [
            "\(directory)/2.1/claude.app/Contents/MacOS/claude",                  // two components
            "\(directory)/2.1.2.4/claude.app/Contents/MacOS/claude",              // four components
            "\(directory)/2.1.x/claude.app/Contents/MacOS/claude",                // not numeric
            "\(directory)//claude.app/Contents/MacOS/claude",                     // empty version
            "\(directory)/2.1.284/other.app/Contents/MacOS/claude",               // wrong bundle
            "\(directory)/2.1.284/claude.app/Contents/MacOS/claude-helper",       // wrong executable
            "\(directory)/../evil/2.1.284/claude.app/Contents/MacOS/claude",      // not directly under the directory
            "/tmp/2.1.284/claude.app/Contents/MacOS/claude",                      // outside the engine directory
            "\(directory)/2.1.284/nested/claude.app/Contents/MacOS/claude"
        ] {
            XCTAssertFalse(accepts(path), path)
        }
    }
}
