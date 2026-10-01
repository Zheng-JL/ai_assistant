import XCTest
@testable import CodexStatusCore

final class TokenUsageTests: XCTestCase {
    private var home: URL!
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("token-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions/2026/10/01"),
                                               withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/proj"),
                                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func stamp(_ offset: TimeInterval = 0) -> String { iso.string(from: Date().addingTimeInterval(offset)) }

    // MARK: Codex

    private func codexFile(_ name: String = "rollout-2026-10-01T00-00-00-a.jsonl") -> URL {
        home.appendingPathComponent(".codex/sessions/2026/10/01/\(name)")
    }

    private func meta(cwd: String = "/Users/me/work/my-app") -> String {
        #"{"timestamp":"\#(stamp())","type":"session_meta","payload":{"id":"x","cwd":"\#(cwd)","base_instructions":"SECRET TEXT"}}"#
    }

    private func codexToken(input: Int, cached: Int, output: Int, at offset: TimeInterval = 0) -> String {
        #"{"timestamp":"\#(stamp(offset))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testCodexCountsGrowthNotRepeatedCumulativeTotals() async throws {
        try write([meta(), codexToken(input: 1000, cached: 600, output: 50),
                   codexToken(input: 1000, cached: 600, output: 50),     // repeated event adds nothing
                   codexToken(input: 3000, cached: 2000, output: 150)], to: codexFile())
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.codex, TokenTotals(newInput: 1000, cached: 2000, output: 150))
        XCTAssertEqual(report.codexProjects.map(\.project), ["my-app"])
    }

    func testCodexIgnoresEventsFromEarlierDaysButKeepsBaseline() async throws {
        try write([meta(), codexToken(input: 5000, cached: 4000, output: 100, at: -3 * 86_400),
                   codexToken(input: 5500, cached: 4200, output: 130)], to: codexFile())
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.codex, TokenTotals(newInput: 300, cached: 200, output: 30))
    }

    func testCounterResetCountsNewValueInsteadOfNegative() async throws {
        try write([meta(), codexToken(input: 1000, cached: 0, output: 100),
                   codexToken(input: 200, cached: 0, output: 20)], to: codexFile())
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.codex, TokenTotals(newInput: 1200, cached: 0, output: 120))
    }

    func testIncrementalReadPicksUpAppendedLinesAndWaitsForPartialLine() async throws {
        let url = codexFile()
        try write([meta(), codexToken(input: 100, cached: 0, output: 10)], to: url)
        let source = TokenUsageSource(home: home)
        var report = await source.sample()
        XCTAssertEqual(report.codex.all, 110)
        let next = codexToken(input: 400, cached: 100, output: 40)
        try append(String(next.prefix(30)), to: url)                       // half-written line
        report = await source.sample()
        XCTAssertEqual(report.codex.all, 110)
        try append(String(next.dropFirst(30)) + "\n", to: url)
        report = await source.sample()
        // First event: 100 new + 10 out. Second adds 300 input (100 cached) and 30 out.
        XCTAssertEqual(report.codex, TokenTotals(newInput: 300, cached: 100, output: 40))
    }

    func testTruncatedFileTriggersFullRecount() async throws {
        let url = codexFile()
        try write([meta(), codexToken(input: 1000, cached: 0, output: 100)], to: url)
        let source = TokenUsageSource(home: home)
        _ = await source.sample()
        try write([meta(), codexToken(input: 50, cached: 0, output: 5)], to: url)
        let report = await source.sample()
        XCTAssertEqual(report.codex.all, 55)
    }

    func testInfoNullAndGarbageLinesAreIgnored() async throws {
        let nullInfo = #"{"timestamp":"\#(stamp())","type":"event_msg","payload":{"type":"token_count","info":null}}"#
        try write([meta(), nullInfo, "not json total_token_usage token_count",
                   codexToken(input: 10, cached: 0, output: 1)], to: codexFile())
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.codex.all, 11)
    }

    func testNonRolloutFilesAndOldFilesAreNotFollowed() async throws {
        try write([meta(), codexToken(input: 10, cached: 0, output: 1)],
                  to: codexFile("notes.jsonl"))
        let old = codexFile("rollout-2026-01-01T00-00-00-b.jsonl")
        try write([meta(), codexToken(input: 10, cached: 0, output: 1)], to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)],
                                              ofItemAtPath: old.path)
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.codex.all, 0)
    }

    // MARK: Claude

    private func claude(id: String?, input: Int, creation: Int, read: Int, output: Int,
                        cwd: String = "/Users/me/work/claude-proj", at offset: TimeInterval = 0) -> String {
        let idPart = id.map { #""id":"\#($0)","# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(stamp(offset))","cwd":"\#(cwd)","message":{\#(idPart)"content":[{"type":"text","text":"PRIVATE"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(creation),"cache_read_input_tokens":\#(read),"output_tokens":\#(output)}}}"#
    }

    private func claudeFile(_ name: String = "s1.jsonl") -> URL {
        home.appendingPathComponent(".claude/projects/proj/\(name)")
    }

    func testClaudeDeduplicatesByMessageIdAcrossLinesAndFiles() async throws {
        try write([claude(id: "m1", input: 2, creation: 100, read: 500, output: 10),
                   claude(id: "m1", input: 2, creation: 100, read: 500, output: 40),   // later reading wins
                   claude(id: "m2", input: 1, creation: 0, read: 300, output: 20)], to: claudeFile())
        try write([claude(id: "m2", input: 1, creation: 0, read: 300, output: 20)], to: claudeFile("copy.jsonl"))
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.claude, TokenTotals(newInput: 2 + 100 + 1, cached: 800, output: 60))
        XCTAssertEqual(report.claudeProjects.map(\.project), ["claude-proj"])
    }

    func testClaudeSkipsOtherDaysMissingIdsAndUsagelessLines() async throws {
        let userLine = #"{"type":"user","timestamp":"\#(stamp())","message":{"role":"user","content":"mention of \"usage\" in text"}}"#
        try write([claude(id: "old", input: 9, creation: 0, read: 0, output: 9, at: -3 * 86_400),
                   claude(id: nil, input: 9, creation: 0, read: 0, output: 9), userLine,
                   claude(id: "ok", input: 5, creation: 0, read: 0, output: 5)], to: claudeFile())
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.claude.all, 10)
    }

    func testReportsRankProjectsByNonCacheTokensAndLimitToFive() async throws {
        for index in 0..<7 {
            try write([meta(cwd: "/w/p\(index)"), codexToken(input: 1000 * (index + 1), cached: 0, output: 0)],
                      to: codexFile("rollout-2026-10-01T00-00-0\(index)-a.jsonl"))
        }
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.codexProjects.map(\.project), ["p6", "p5", "p4", "p3", "p2"])
    }

    func testMissingDirectoriesGiveEmptyReport() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        let report = await TokenUsageSource(home: empty).sample()
        XCTAssertEqual(report.codex, TokenTotals())
        XCTAssertEqual(report.claude, TokenTotals())
    }

    func testCodexContextComesFromLatestEventAndFileNameID() async throws {
        let id = "019da1c2-0000-7000-8000-abcdef012345"
        let event = #"{"timestamp":"\#(stamp())","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":10},"last_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":10,"total_tokens":160},"model_context_window":1000}}}"#
        try write([meta(), codexToken(input: 100, cached: 0, output: 5), event],
                  to: codexFile("rollout-2026-10-01T00-00-00-\(id).jsonl"))
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.contexts[id]?.used, 160)
        XCTAssertEqual(report.contexts[id]?.fraction, 0.16)
    }

    func testClaudeContextUsesLatestMainThreadMessageWithoutWindow() async throws {
        let id = "8c7da535-5202-4b95-b6fd-78eeb314503b"
        let side = #"{"isSidechain":true,"type":"assistant","timestamp":"\#(stamp(5))","message":{"id":"side","usage":{"input_tokens":999999,"output_tokens":1}}}"#
        try write([claude(id: "m1", input: 1, creation: 10, read: 100, output: 5, at: -2),
                   claude(id: "m2", input: 2, creation: 20, read: 400, output: 5, at: -1), side],
                  to: claudeFile("\(id).jsonl"))
        let report = await TokenUsageSource(home: home).sample()
        XCTAssertEqual(report.contexts[id]?.used, 422)
        XCTAssertNil(report.contexts[id]?.window)
    }

    func testTokenFormatting() {
        XCTAssertEqual(formatTokens(0), "0")
        XCTAssertEqual(formatTokens(999), "999")
        XCTAssertEqual(formatTokens(1_500), "1.5K")
        XCTAssertEqual(formatTokens(999_960), "1.0M")
        XCTAssertEqual(formatTokens(62_126_000), "62.1M")
        XCTAssertEqual(formatTokens(2_500_000_000), "2.50B")
        XCTAssertEqual(TokenTotals(newInput: 3, cached: 100, output: 4).withoutCache, 7)
    }
}
