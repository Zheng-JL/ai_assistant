import Foundation

public struct SummaryPlan: Sendable {
    public let prompt: BuiltPrompt
    public let claudeSessions: Int
    public let codexSessions: Int
    public let redactions: Int
    /// Rough token estimate: mixed Chinese and English text averages a little under two characters per token.
    public var estimatedTokens: Int { prompt.chars / 2 }
}

public struct SummaryOutput: Sendable, Equatable {
    public let journalURL: URL
    public let lessonsURL: URL?
}

public enum SummaryError: Error, LocalizedError, Equatable {
    case nothingToSummarize
    public var errorDescription: String? { "今天还没有可以总结的对话" }
}

/// Reads today's conversations, strips secrets, asks the configured model for a report plus an updated
/// lessons list, and saves both as plain Markdown files.
public struct DailySummarizer: Sendable {
    private let extractor: TranscriptExtractor
    private let supportDirectory: URL
    private let client: ModelClient

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, supportDirectory: URL,
                client: ModelClient = ModelClient()) {
        extractor = TranscriptExtractor(home: home)
        self.supportDirectory = supportDirectory
        self.client = client
    }

    public var journalDirectory: URL { supportDirectory.appendingPathComponent("journal", isDirectory: true) }
    public var lessonsURL: URL { supportDirectory.appendingPathComponent("lessons.md") }

    public func journalURL(dayKey: String) -> URL { journalDirectory.appendingPathComponent("\(dayKey).md") }

    public func readLessons() -> String {
        (try? String(contentsOf: lessonsURL, encoding: .utf8)).map { String($0.prefix(30_000)) } ?? ""
    }

    /// Everything that would be sent, without sending it. Nil when there is nothing to summarise.
    public func prepare(now: Date = Date(), maxChars: Int = 60_000, calendar: Calendar = .current) -> SummaryPlan? {
        let dayKey = DailyStats.dayKey(now, calendar: calendar)
        let raw = extractor.extract(dayKey: dayKey, calendar: calendar, now: now)
        guard !raw.isEmpty else { return nil }
        let redactor = Redactor()
        var redactions = 0
        let cleaned = raw.map { session -> SessionTranscript in
            let messages = session.messages.map { message -> TranscriptMessage in
                let result = redactor.redact(message.text)
                redactions += result.count
                return TranscriptMessage(role: message.role, text: result.text, at: message.at)
            }
            return SessionTranscript(provider: session.provider, sessionID: session.sessionID,
                                     project: session.project, messages: messages)
        }
        let lessons = redactor.redact(readLessons()).text
        let prompt = buildSummaryPrompt(transcripts: cleaned, existingLessons: lessons, dayKey: dayKey, maxChars: maxChars)
        return SummaryPlan(prompt: prompt, claudeSessions: cleaned.filter { $0.provider == "claude" }.count,
                           codexSessions: cleaned.filter { $0.provider == "codex" }.count, redactions: redactions)
    }

    public func run(_ plan: SummaryPlan, config: ModelConfig, now: Date = Date(),
                    calendar: Calendar = .current) async throws -> SummaryOutput {
        let reply = try await client.complete(config: config, system: plan.prompt.system, user: plan.prompt.user)
        let parsed = parseSummaryReply(reply)
        let dayKey = DailyStats.dayKey(now, calendar: calendar)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        let journal = parsed.journal + "\n\n---\n生成于 \(stamp) · 模型 \(config.model)\n"
        let journalFile = journalURL(dayKey: dayKey)
        try journal.write(to: journalFile, atomically: true, encoding: .utf8)

        var savedLessons: URL?
        if let lessons = parsed.lessons, lessons.count <= 30_000 {
            if FileManager.default.fileExists(atPath: lessonsURL.path) {
                let backup = supportDirectory.appendingPathComponent("lessons.md.bak")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: lessonsURL, to: backup)
            }
            try (lessons + "\n").write(to: lessonsURL, atomically: true, encoding: .utf8)
            savedLessons = lessonsURL
        }
        return SummaryOutput(journalURL: journalFile, lessonsURL: savedLessons)
    }
}
