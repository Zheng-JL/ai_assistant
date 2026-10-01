import Foundation
import XCTest
@testable import CodexStatusCore

final class StatusTests: XCTestCase {
    let id = "01a0edcc-dae0-7461-93a9-d42871895837"
    let otherID = "01a0edc7-ba2c-73c2-9fbc-00e0258a8f6f"
    let at = "2026-09-29T15:00:00.000Z"

    func record(_ type: String, turn: String = "t1", timestamp: String? = nil) throws -> StatusRecord {
        let object: [String: Any] = [
            "type": "event_msg", "timestamp": timestamp ?? at,
            "payload": ["type": type, "turn_id": turn]
        ]
        return try JSONDecoder().decode(StatusRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func unread(_ identities: [String: [String: [String]]], version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "electron-thread-read-state-v1": ["version": version, "unreadByIdentity": identities]
        ])
    }

    func testStandardHostHashMatchesInstalledSchema() {
        XCTAssertEqual(UnreadState.standardLocalHostKey,
                       "local:092af2cb59bdd804c6f7f1cd1d85464b682974e43cd517397d25510024034d1c")
    }

    func testUnreadFiltersRemoteAndDeduplicates() throws {
        let parsed = try UnreadState.decode(unread([
            "identity": [UnreadState.standardLocalHostKey: [id, id], "ssh:remote": [otherID]]
        ]))
        XCTAssertEqual(parsed.threadIDs, [id])
    }

    func testUnreadRejectsMultipleIdentities() throws {
        XCTAssertThrowsError(try UnreadState.decode(unread(["one": [:], "two": [:]])))
    }

    func testUnreadRejectsUnknownVersion() throws {
        XCTAssertThrowsError(try UnreadState.decode(unread([:], version: 2)))
    }

    func testUnreadRejectsLegacyOnlyState() {
        XCTAssertThrowsError(try UnreadState.decode(Data(#"{"electron-persisted-atom-state":{"unread-thread-ids-by-host-v1":{"local":[]}}}"#.utf8)))
    }

    func testUnreadRejectsCustomLocalConnection() throws {
        XCTAssertThrowsError(try UnreadState.decode(unread(["one": ["local:different": []]])))
    }

    func testUnreadRejectsMalformedIdentifiers() throws {
        XCTAssertThrowsError(try UnreadState.decode(unread(["one": [UnreadState.standardLocalHostKey: ["bad"]]])))
    }

    func testEmptyUnreadStateIsUnknown() throws {
        XCTAssertThrowsError(try UnreadState.decode(unread([:])))
    }

    func testMissingLocalHostIsUnknown() throws {
        XCTAssertThrowsError(try UnreadState.decode(unread(["one": [:]])))
        XCTAssertThrowsError(try UnreadState.decode(unread(["one": ["ssh:remote": []]])))
    }

    func testExplicitEmptyLocalUnreadStateIsZero() throws {
        let parsed = try UnreadState.decode(unread(["one": [UnreadState.standardLocalHostKey: []]]))
        XCTAssertTrue(parsed.threadIDs.isEmpty)
    }

    func testLifecycleStartsAndCompletes() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        XCTAssertEqual(state.phase, .running)
        XCTAssertNotNil(state.startedAt)
        try state.apply(record("task_complete"))
        XCTAssertEqual(state.phase, .completed)
    }

    func testCurrentNumericStartedAtDoesNotDiscardLifecycle() throws {
        let data = Data(#"{"type":"event_msg","timestamp":"2026-09-29T15:00:00.000Z","payload":{"type":"task_started","turn_id":"t1","started_at":1790694000000}}"#.utf8)
        var state = Lifecycle()
        state.apply(try JSONDecoder().decode(StatusRecord.self, from: data))
        XCTAssertEqual(state.phase, .running)
        XCTAssertNotNil(state.startedAt)
    }

    func testTimestampWithoutFractionalSeconds() {
        XCTAssertNotNil(eventDate("2026-09-29T15:00:00Z"))
    }

    func testErrorWithoutTerminalStatusIsUnknownNotFinished() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        try state.apply(record("error"))
        XCTAssertEqual(state.phase, .unknown)
    }

    func testOldTurnCompletionDoesNotFinishNewTurn() throws {
        var state = Lifecycle()
        try state.apply(record("task_started", turn: "new"))
        try state.apply(record("task_complete", turn: "old"))
        XCTAssertEqual(state.phase, .running)
    }

    func testInterruptedIsNotCompleted() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        try state.apply(record("turn_aborted"))
        XCTAssertEqual(state.phase, .interrupted)
    }

    func testRunningWithoutLiveWriterIsUnknown() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        XCTAssertEqual(state.phase(with: []), .unknown)
    }

    func testRestartedEngineDoesNotResurrectOldTask() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: state.startedAt!.addingTimeInterval(1))
        XCTAssertEqual(state.phase(with: [writer]), .unknown)
    }

    func testLiveWriterAllowsRunning() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: state.startedAt!.addingTimeInterval(-1))
        XCTAssertEqual(state.phase(with: [writer]), .running)
    }

    func testPendingInputIsSeparateFromRunning() throws {
        var state = Lifecycle()
        try state.apply(record("task_started"))
        let call = Data(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"c1"}}"#.utf8)
        state.apply(try JSONDecoder().decode(StatusRecord.self, from: call))
        XCTAssertEqual(state.phase, .waitingForInput)
        let result = Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1"}}"#.utf8)
        state.apply(try JSONDecoder().decode(StatusRecord.self, from: result))
        XCTAssertEqual(state.phase, .running)
    }

    func testHeaderExcludesSubagent() throws {
        let data = Data("""
        {"type":"session_meta","payload":{"id":"\(id)","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{}}}}}
        """.utf8)
        XCTAssertFalse(try JSONDecoder().decode(RolloutHeader.self, from: data).isPrimaryDesktop)
    }

    func testHeaderExcludesCLI() throws {
        let data = Data("""
        {"type":"session_meta","payload":{"id":"\(id)","originator":"codex_cli_rs","source":"cli"}}
        """.utf8)
        XCTAssertFalse(try JSONDecoder().decode(RolloutHeader.self, from: data).isPrimaryDesktop)
    }

    func testReaderIgnoresPartialTerminalLine() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","originator":"Codex Desktop","source":"vscode"}}"#
        let start = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_started","turn_id":"t1"}}"#
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#
        try Data("\(header)\n\(start)\n\(complete)".utf8).write(to: file)
        XCTAssertEqual(try RolloutReader().read(file).lifecycle.phase, .running)
    }

    func testReaderFindsLongRunningTurnBeyondInitialTail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","originator":"Codex Desktop","source":"vscode"}}"#
        let start = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_started","turn_id":"t1"}}"#
        let ignored = #"{"type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "x", count: 200_000))"}}"#
        try Data("\(header)\n\(start)\n\(ignored)\n".utf8).write(to: file)
        XCTAssertEqual(try RolloutReader().read(file).lifecycle.phase, .running)
    }

    func testMoreThanFiftyCompletedUnreadSessions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var ids: [String] = []
        var index = ""
        for _ in 0..<75 {
            let identifier = UUID().uuidString.lowercased()
            ids.append(identifier)
            index += #"{"id":"\#(identifier)","thread_name":"Synthetic"}"# + "\n"
            let header = #"{"type":"session_meta","payload":{"id":"\#(identifier)","originator":"Codex Desktop","source":"vscode"}}"#
            let complete = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_complete","turn_id":"t1"}}"#
            try Data("\(header)\n\(complete)\n".utf8).write(to: sessions.appendingPathComponent("rollout-2026-09-29T15-00-00-\(identifier).jsonl"))
        }
        try Data(index.utf8).write(to: root.appendingPathComponent("session_index.jsonl"))
        try unread(["one": [UnreadState.standardLocalHostKey: ids]])
            .write(to: root.appendingPathComponent(".codex-global-state.json"))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertEqual(result.completedUnreadCount, 75)
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertNil(result.notice)
    }

    func testDamagedNewStartDoesNotRetainOldCompletion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","originator":"Codex Desktop","source":"vscode"}}"#
        let complete = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_complete","turn_id":"old"}}"#
        let damaged = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_started","turn_id":42}}"#
        try Data("\(header)\n\(complete)\n\(damaged)\n".utf8).write(to: file)
        XCTAssertEqual(try RolloutReader().read(file).lifecycle.phase, .unknown)
    }

    func testCompletionWithoutTimestampIsUnknown() throws {
        var state = Lifecycle()
        let data = Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#.utf8)
        state.apply(try JSONDecoder().decode(StatusRecord.self, from: data))
        XCTAssertEqual(state.phase, .unknown)
    }

    func testStartWithoutTurnIDIsUnknown() throws {
        var state = Lifecycle()
        try state.apply(record("task_complete"))
        let data = Data(#"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_started"}}"#.utf8)
        state.apply(try JSONDecoder().decode(StatusRecord.self, from: data))
        XCTAssertEqual(state.phase, .unknown)
    }

    func testValidTerminalAfterDamagedRecordRestoresCertainty() throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = activeRollout(in: root)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let terminal = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"task_complete","turn_id":"t1"}}"#
        try handle.write(contentsOf: Data("not valid json\n\(terminal)\n".utf8))
        XCTAssertEqual(try RolloutReader().read(file).lifecycle.phase, .completed)
    }

    func testDamagedInputCallDoesNotRemainRunning() throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = activeRollout(in: root)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let call = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":42}}"#
        try handle.write(contentsOf: Data("\(call)\n".utf8))
        XCTAssertEqual(try RolloutReader().read(file).lifecycle.phase, .unknown)
    }

    func testArchiveBackupDoesNotHideActiveSession() async throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try Data("damaged backup".utf8).write(to: archived.appendingPathComponent("old-backup-\(id).jsonl"))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: .distantPast)
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [writer])
        XCTAssertEqual(result.runningCount, 1)
    }

    func testUnreadHeaderIDMismatchIsUnknown() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id], headerID: otherID)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertNil(result.completedUnreadCount)
    }

    func testUnknownSourceDoesNotReportZero() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","originator":"Codex Desktop","source":"future_source"}}"#
        try Data("\(header)\n".utf8).write(to: activeRollout(in: root))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertNil(result.completedUnreadCount)
    }

    func testCLIIsPositivelyExcluded() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","originator":"codex_cli_rs","source":"cli"}}"#
        try Data("\(header)\n".utf8).write(to: activeRollout(in: root))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertEqual(result.completedUnreadCount, 0)
        XCTAssertNil(result.notice)
    }

    func testVerifiedArchiveIsExcluded() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = activeRollout(in: root)
        try FileManager.default.moveItem(at: file, to: archived.appendingPathComponent(file.lastPathComponent))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertEqual(result.completedUnreadCount, 0)
        XCTAssertNil(result.notice)
    }

    func testActiveSessionTakesPrecedenceOverArchiveCopy() async throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = activeRollout(in: root)
        try FileManager.default.copyItem(at: file, to: archived.appendingPathComponent(file.lastPathComponent))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: .distantPast)
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [writer])
        XCTAssertEqual(result.runningCount, 1)
    }

    func testMismatchedArchiveHeaderIsUnknown() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id], headerID: otherID)
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let file = activeRollout(in: root)
        try FileManager.default.moveItem(at: file, to: archived.appendingPathComponent(file.lastPathComponent))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertNil(result.completedUnreadCount)
    }

    func testSuffixedFilenameKeepsOriginalIdentity() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = activeRollout(in: root)
        let renamed = file.deletingPathExtension().lastPathComponent + "_\(otherID).jsonl"
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent(renamed))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertEqual(result.completedUnreadCount, 1)
    }

    func testUnindexedInternalWriterIsExcluded() async throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("session_index.jsonl"))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: .distantPast)
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [writer])
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertNil(result.notice)
    }

    func testUnindexedSubagentUnreadIsExcluded() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("session_index.jsonl"))
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{}}}}}"#
        try Data("\(header)\n".utf8).write(to: activeRollout(in: root))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: .distantPast)
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [writer])
        XCTAssertEqual(result.runningCount, 0)
        XCTAssertEqual(result.completedUnreadCount, 0)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNil(result.notice)
    }

    func testUnindexedPrimaryUnreadIsUnknown() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("session_index.jsonl"))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertNil(result.completedUnreadCount)
    }

    func testMissingIndexedRolloutIsUnknown() async throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: activeRollout(in: root))
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: .distantPast)
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [writer])
        XCTAssertNil(result.runningCount)
    }

    func testMalformedTitleDoesNotBreakCounts() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((#"{"id":"\#(id)","thread_name":42}"# + "\n").utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [])
        XCTAssertEqual(result.completedUnreadCount, 1)
    }

    func testReadStateChangesWithoutChangingRollout() async throws {
        let root = try fixture(phase: "task_complete", unreadIDs: [id])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LocalStatusSource(home: root)
        let first = await source.assemble(now: Date(), writers: [])
        XCTAssertEqual(first.completedUnreadCount, 1)
        try unread(["one": [UnreadState.standardLocalHostKey: []]])
            .write(to: root.appendingPathComponent(".codex-global-state.json"))
        let second = await source.assemble(now: Date(), writers: [])
        XCTAssertEqual(second.completedUnreadCount, 0)
    }

    func testDuplicateWritersCountOneSession() async throws {
        let root = try fixture(phase: "task_started", unreadIDs: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WriterRecord(threadID: id, pid: 1, processStartedAt: .distantPast)
        let result = await LocalStatusSource(home: root).assemble(now: Date(), writers: [writer, writer])
        XCTAssertEqual(result.runningCount, 1)
    }

    func testCodexNotRunningIsUnknown() async {
        let result = await LocalStatusSource().sample(appPID: nil, appBundle: nil)
        XCTAssertFalse(result.appIsRunning)
        XCTAssertNil(result.runningCount)
        XCTAssertNil(result.completedUnreadCount)
    }

    func testUnverifiedAppBundleIsUnknown() async {
        let result = await LocalStatusSource().sample(appPID: 1, appBundle: nil)
        XCTAssertTrue(result.appIsRunning)
        XCTAssertNil(result.runningCount)
        XCTAssertNil(result.completedUnreadCount)
    }

    private func activeRollout(in root: URL) -> URL {
        root.appendingPathComponent("sessions/rollout-2026-09-29T15-00-00-\(id).jsonl")
    }

    private func fixture(phase: String, unreadIDs: [String], headerID: String? = nil) throws -> URL {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let header = #"{"type":"session_meta","payload":{"id":"\#(headerID ?? id)","originator":"Codex Desktop","source":"vscode"}}"#
        let event = #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"\#(phase)","turn_id":"t1","started_at":1790694000000}}"#
        try Data("\(header)\n\(event)\n".utf8)
            .write(to: sessions.appendingPathComponent("rollout-2026-09-29T15-00-00-\(id).jsonl"))
        try Data((#"{"id":"\#(id)","thread_name":"Synthetic"}"# + "\n").utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))
        try unread(["one": [UnreadState.standardLocalHostKey: unreadIDs]])
            .write(to: root.appendingPathComponent(".codex-global-state.json"))
        return root
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-status-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
