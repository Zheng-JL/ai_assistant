import XCTest
@testable import CodexStatusCore

/// Test secrets are assembled at run time so the source never contains a complete, realistic-looking token
/// (secret scanners on public hosts flag those even when they are fake).
private func fake(_ parts: String...) -> String { parts.joined() }

final class RedactorTests: XCTestCase {
    private let redactor = Redactor()

    func testCommonSecretFormatsAreHidden() {
        let samples = [
            "key \(fake("sk-", "ant-api03-abcdefghijklmnopqrstuvwx1234")) end", fake("AKI", "AABCDEFGHIJKLMNOP"), fake("gh", "p_abcdefghijklmnopqrstuvwxyz0123456789"),
            fake("xo", "xb-1234567890-abcdefghij"), "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456",
            fake("ey", "JhbGciOiJIUzI1NiJ9.", "ey", "JzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop"),
            "https://user:hunter2pass@example.com/path", "API_KEY=abcdef123456", "password: \"correct-horse-battery\"",
            fake("-----BEGIN RSA ", "PRIVATE KEY-----") + "\nMIIEow\nline2\n" + fake("-----END RSA ", "PRIVATE KEY-----"), "stripe " + fake("sk_", "live_abcdefghij123456")
        ]
        for sample in samples {
            let result = redactor.redact(sample)
            XCTAssertGreaterThan(result.count, 0, sample)
            XCTAssertTrue(result.text.contains("已隐藏"), sample)
        }
        let key = redactor.redact("export OPENAI_API_KEY=" + fake("sk-", "proj-abcdefghijklmnop1234567890"))
        XCTAssertFalse(key.text.contains("abcdefghijklmnop"))
        XCTAssertTrue(key.text.contains("OPENAI_API_KEY"))     // the name stays, only the value goes
    }

    func testOrdinaryTextIsLeftAlone() {
        for text in ["修复登录失败的问题", "max_tokens: 4096", "tokens: 1.2M", "git commit 5f3a9c1 fixed it",
                     "访问 https://example.com/docs?page=2", "password 要怎么设计更安全？", "sk-short"] {
            let result = redactor.redact(text)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.count, 0)
        }
    }
}

final class ExtractorTests: XCTestCase {
    private var home: URL!
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let claudeID = "8c7da535-5202-4b95-b6fd-78eeb314503b"
    private let codexID = "019da1c2-0000-7000-8000-abcdef012345"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("extract-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/proj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions/2026/10/01"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func stamp(_ offset: TimeInterval = 0) -> String { iso.string(from: Date().addingTimeInterval(offset)) }
    private func write(_ lines: [String], to url: URL) throws { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }

    func testClaudeKeepsOnlyConversationText() throws {
        let t = stamp()
        try write([
            #"{"type":"user","timestamp":"\#(t)","cwd":"/w/my-app","message":{"role":"user","content":"帮我修复登录"}}"#,
            #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"thinking","thinking":"SECRET THOUGHT"},{"type":"text","text":"好的，先看日志"},{"type":"tool_use","name":"Bash","input":{"command":"cat /etc/passwd"}}]}}"#,
            #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"tool_result","content":"HUGE OUTPUT"}]}}"#,
            #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"text","text":"<system-reminder>noise</system-reminder>"}]}}"#,
            #"{"type":"user","isMeta":true,"timestamp":"\#(t)","message":{"content":"meta line"}}"#,
            #"{"type":"assistant","isSidechain":true,"timestamp":"\#(t)","message":{"content":[{"type":"text","text":"sub-agent chatter"}]}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-3 * 86_400))","message":{"content":[{"type":"text","text":"old day"}]}}"#
        ], to: home.appendingPathComponent(".claude/projects/proj/\(claudeID).jsonl"))
        let key = DailyStats.dayKey(Date())
        let sessions = TranscriptExtractor(home: home).extract(dayKey: key)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].project, "my-app")
        XCTAssertEqual(sessions[0].messages.map(\.text), ["帮我修复登录", "好的，先看日志"])
        let joined = sessions[0].messages.map(\.text).joined()
        for leaked in ["SECRET THOUGHT", "HUGE OUTPUT", "passwd", "noise", "meta line", "sub-agent", "old day"] {
            XCTAssertFalse(joined.contains(leaked), leaked)
        }
    }

    func testCodexKeepsUserAndAssistantMessagesOnly() throws {
        let t = stamp()
        try write([
            #"{"timestamp":"\#(t)","type":"session_meta","payload":{"id":"x","cwd":"/w/codex-proj"}}"#,
            #"{"timestamp":"\#(t)","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"SYSTEM RULES"}]}}"#,
            #"{"timestamp":"\#(t)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"timestamp":"\#(t)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"写一个脚本"}]}}"#,
            #"{"timestamp":"\#(t)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"已写好"}]}}"#,
            #"{"timestamp":"\#(t)","type":"response_item","payload":{"type":"function_call_output","output":"TOOL OUTPUT"}}"#
        ], to: home.appendingPathComponent(".codex/sessions/2026/10/01/rollout-2026-10-01T00-00-00-\(codexID).jsonl"))
        let sessions = TranscriptExtractor(home: home).extract(dayKey: DailyStats.dayKey(Date()))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].provider, "codex")
        XCTAssertEqual(sessions[0].project, "codex-proj")
        XCTAssertEqual(sessions[0].messages.map(\.text), ["写一个脚本", "已写好"])
    }

    func testSubAgentFilesAndEmptyDaysProduceNothing() throws {
        try write([#"{"type":"user","timestamp":"\#(stamp())","message":{"content":"x"}}"#],
                  to: home.appendingPathComponent(".claude/projects/proj/agent-abc123.jsonl"))
        XCTAssertTrue(TranscriptExtractor(home: home).extract(dayKey: DailyStats.dayKey(Date())).isEmpty)
        XCTAssertTrue(TranscriptExtractor(home: home).extract(dayKey: "1999-01-01").isEmpty)
    }
}

final class PromptTests: XCTestCase {
    private func session(_ id: String, _ count: Int, length: Int, project: String? = "app") -> SessionTranscript {
        SessionTranscript(provider: "claude", sessionID: id, project: project, messages: (0..<count).map {
            TranscriptMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "消息\($0)：" + String(repeating: "字", count: length), at: nil)
        })
    }

    func testSmallDayIsSentWholeWithLessonsAndInstructions() {
        let prompt = buildSummaryPrompt(transcripts: [session("11111111-aaaa", 4, length: 20)], existingLessons: "- [通用] 先测再改",
                                        dayKey: "2026-10-01", maxChars: 60_000)
        XCTAssertTrue(prompt.user.contains("先测再改"))
        XCTAssertTrue(prompt.user.contains("项目：app"))
        XCTAssertTrue(prompt.user.contains("消息3"))
        XCTAssertTrue(prompt.system.contains(journalMarker) && prompt.system.contains(lessonsMarker))
        XCTAssertEqual(prompt.messages, 4)
    }

    func testHugeDayIsCompressedUnderTheBudgetKeepingTheUsersWordsAndEnds() {
        let big = session("22222222-bbbb", 400, length: 2_000)
        let prompt = buildSummaryPrompt(transcripts: [big, session("33333333-cccc", 300, length: 2_000)], existingLessons: "",
                                        dayKey: "2026-10-01", maxChars: 30_000)
        XCTAssertLessThan(prompt.chars, 36_000)
        XCTAssertTrue(prompt.user.contains("消息0"))
        XCTAssertTrue(prompt.user.contains("消息399"))
        XCTAssertTrue(prompt.user.contains("中间省略"))
    }

    func testEmptyDayStillBuildsAReadablePrompt() {
        XCTAssertTrue(buildSummaryPrompt(transcripts: [], existingLessons: "", dayKey: "d", maxChars: 10_000).user.contains("没有可总结"))
    }

    func testReplyParsingHandlesMarkersFencesAndMissingParts() {
        let both = parseSummaryReply("===日报===\n# 日报\n内容\n===踩坑清单===\n- [通用] 规则 —— 原因\n")
        XCTAssertEqual(both.journal, "# 日报\n内容")
        XCTAssertEqual(both.lessons, "- [通用] 规则 —— 原因")
        let fenced = parseSummaryReply("===日报===\n```markdown\n# 日报\n```\n===踩坑清单===\n```\n- a\n```")
        XCTAssertEqual(fenced.journal, "# 日报")
        XCTAssertEqual(fenced.lessons, "- a")
        let none = parseSummaryReply("只有一段话")
        XCTAssertEqual(none.journal, "只有一段话")
        XCTAssertNil(none.lessons)
        XCTAssertNil(parseSummaryReply("===日报===\nx\n===踩坑清单===\n   \n").lessons)
    }
}

final class MockProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.lastBody = data
        } else { Self.lastBody = request.httpBody }
        let (status, body) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelClientTests: XCTestCase {
    private func client() -> ModelClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return ModelClient(session: URLSession(configuration: configuration))
    }
    private let key = "sk-test-SECRETSECRETSECRET"

    func testEndpointNormalisation() throws {
        func url(_ endpoint: String, _ format: APIFormat = .openAI) throws -> String {
            try ModelClient.requestURL(for: ModelConfig(format: format, endpoint: endpoint, model: "m", apiKey: "k")).absoluteString
        }
        XCTAssertEqual(try url("https://api.example.com"), "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(try url("https://api.example.com/v1/"), "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(try url("https://api.example.com/v1/chat/completions"), "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(try url("https://x.org/api/paas/v4"), "https://x.org/api/paas/v4/chat/completions")
        XCTAssertEqual(try url("https://api.anthropic.com", .anthropic), "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(try url("http://localhost:11434/v1"), "http://localhost:11434/v1/chat/completions")
    }

    func testRejectsBadAndInsecureEndpoints() {
        func error(_ endpoint: String) -> ModelError? {
            do { _ = try ModelClient.requestURL(for: ModelConfig(format: .openAI, endpoint: endpoint, model: "m", apiKey: "k")); return nil }
            catch { return error as? ModelError }
        }
        XCTAssertEqual(error("http://api.example.com/v1"), .insecureEndpoint)
        XCTAssertEqual(error("ftp://x.com"), .invalidEndpoint)
        XCTAssertEqual(error("not a url"), .invalidEndpoint)
        XCTAssertEqual(error(""), .invalidEndpoint)
    }

    func testOpenAIRequestShapeAndParsing() async throws {
        MockProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8)) }
        let reply = try await client().complete(config: ModelConfig(format: .openAI, endpoint: "https://api.example.com/v1", model: "gpt-x", apiKey: key),
                                                system: "SYS", user: "USR")
        XCTAssertEqual(reply, "你好")
        let request = MockProtocol.lastRequest!
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let body = try JSONSerialization.jsonObject(with: MockProtocol.lastBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-x")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"]! }, ["system", "user"])
    }

    func testAnthropicRequestShapeAndParsing() async throws {
        MockProtocol.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#.utf8)) }
        let reply = try await client().complete(config: ModelConfig(format: .anthropic, endpoint: "https://api.anthropic.com", model: "claude-x", apiKey: key),
                                                system: "SYS", user: "USR")
        XCTAssertEqual(reply, "A\nB")
        let request = MockProtocol.lastRequest!
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONSerialization.jsonObject(with: MockProtocol.lastBody!) as! [String: Any]
        XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertNotNil(body["max_tokens"])
    }

    func testHTTPErrorsNeverLeakTheKeyAndEmptyRepliesFail() async {
        MockProtocol.handler = { _ in (401, Data("invalid key \(self.key) rejected".utf8)) }
        let config = ModelConfig(format: .openAI, endpoint: "https://api.example.com", model: "m", apiKey: key)
        do { _ = try await client().complete(config: config, system: "s", user: "u"); XCTFail("should throw") }
        catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("401"))
            XCTAssertFalse(text.contains("SECRETSECRET"))
        }
        MockProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"  "}}]}"#.utf8)) }
        do { _ = try await client().complete(config: config, system: "s", user: "u"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? ModelError, .emptyReply) }
    }

    func testMissingFieldsAreReportedBeforeAnyRequest() async {
        MockProtocol.lastRequest = nil
        for config in [ModelConfig(format: .openAI, endpoint: "", model: "m", apiKey: "k"),
                       ModelConfig(format: .openAI, endpoint: "https://a.com", model: " ", apiKey: "k"),
                       ModelConfig(format: .openAI, endpoint: "https://a.com", model: "m", apiKey: "")] {
            do { _ = try await client().complete(config: config, system: "s", user: "u"); XCTFail("should throw") }
            catch { guard case .missingField = error as? ModelError else { return XCTFail("\(error)") } }
        }
        XCTAssertNil(MockProtocol.lastRequest)
    }
}

final class SummarizerEndToEndTests: XCTestCase {
    func testWritesJournalAndLessonsWithBackupAndRedactsBeforeSending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("summ-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/p"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let t = formatter.string(from: Date())
        try (#"{"type":"user","timestamp":"\#(t)","cwd":"/w/app","message":{"content":"我的 key 是 \#(fake("sk-", "ant-api03-abcdefghijklmnopqrstuv"))，帮我部署"}}"# + "\n")
            .write(to: home.appendingPathComponent(".claude/projects/p/8c7da535-5202-4b95-b6fd-78eeb314503b.jsonl"), atomically: true, encoding: .utf8)
        try "- [通用] 旧规则 —— 旧原因\n".write(to: support.appendingPathComponent("lessons.md"), atomically: true, encoding: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let summarizer = DailySummarizer(home: home, supportDirectory: support, client: ModelClient(session: URLSession(configuration: configuration)))
        let plan = try XCTUnwrap(summarizer.prepare())
        XCTAssertEqual(plan.claudeSessions, 1)
        XCTAssertEqual(plan.redactions, 1)
        XCTAssertFalse(plan.prompt.user.contains("abcdefghijklmnop"))
        XCTAssertTrue(plan.prompt.user.contains("旧规则"))

        MockProtocol.handler = { _ in
            let reply = "===日报===\n# 日报\n部署了应用\n===踩坑清单===\n- [app] 部署前先备份 —— 曾覆盖配置"
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reply]]]])
            return (200, data)
        }
        let output = try await summarizer.run(plan, config: ModelConfig(format: .openAI, endpoint: "https://api.example.com", model: "m", apiKey: "k"))
        XCTAssertTrue(try String(contentsOf: output.journalURL, encoding: .utf8).contains("部署了应用"))
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("lessons.md"), encoding: .utf8), "- [app] 部署前先备份 —— 曾覆盖配置\n")
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("lessons.md.bak"), encoding: .utf8), "- [通用] 旧规则 —— 旧原因\n")
        let sent = String(data: MockProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(sent.contains("abcdefghijklmnop"))
    }

    func testNothingToSummarizeReturnsNilPlan() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        XCTAssertNil(DailySummarizer(home: empty, supportDirectory: empty).prepare())
    }
}
