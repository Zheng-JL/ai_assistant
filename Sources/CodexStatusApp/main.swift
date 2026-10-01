import AppKit
import CodexStatusCore
import Foundation

@MainActor
func codexApplication() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" }
}

@MainActor
func claudeApplication() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }
}

if CommandLine.arguments.contains("--diagnose") {
    let source = LocalStatusSource()
    let application = codexApplication()
    let claudeSource = ClaudeStatusSource()
    let claude = claudeApplication()
    let started = Date()
    async let codexResult = source.sample(appPID: application?.processIdentifier, appBundle: application?.bundleURL)
    async let claudeResult = claudeSource.sample(appPID: claude?.processIdentifier, appBundle: claude?.bundleURL)
    let (snapshot, claudeSnapshot) = await (codexResult, claudeResult)
    var report: [String: Any] = [
        "appRunning": snapshot.appIsRunning,
        "running": snapshot.runningCount as Any? ?? NSNull(),
        "completedUnread": snapshot.completedUnreadCount as Any? ?? NSNull(),
        "writerCount": snapshot.inspectedWriterCount,
        "primarySessionsInspected": snapshot.sessions.count,
        "phaseCounts": Dictionary(grouping: snapshot.sessions, by: { $0.phase.rawValue }).mapValues(\.count),
        "notice": snapshot.notice as Any? ?? NSNull(),
        "elapsedMilliseconds": Int(Date().timeIntervalSince(started) * 1000)
    ]
    var claudeReport: [String: Any] = [
        "appRunning": claudeSnapshot.appIsRunning,
        "running": claudeSnapshot.runningCount as Any? ?? NSNull(),
        "completedUnread": claudeSnapshot.completedUnreadCount as Any? ?? NSNull(),
        "engineCount": claudeSnapshot.inspectedEngineCount,
        "primarySessionsInspected": claudeSnapshot.sessions.count,
        "phaseCounts": Dictionary(grouping: claudeSnapshot.sessions, by: { $0.phase.rawValue }).mapValues(\.count),
        "notice": claudeSnapshot.notice as Any? ?? NSNull()
    ]
    if CommandLine.arguments.contains("--details") {
        report["sessions"] = snapshot.sessions.map {
            ["id": $0.id, "phase": $0.phase.rawValue, "unread": $0.isUnread, "project": $0.project as Any? ?? NSNull(),
             "updatedAt": $0.updatedAt?.ISO8601Format() as Any? ?? NSNull()] as [String: Any]
        }
        claudeReport["sessions"] = claudeSnapshot.sessions.map {
            ["id": $0.id, "phase": $0.phase.rawValue, "project": $0.project as Any? ?? NSNull(),
             "updatedAt": $0.updatedAt?.ISO8601Format() as Any? ?? NSNull()] as [String: Any]
        }
    }
    report["claude"] = claudeReport
    let tokenSource = TokenUsageSource()
    let coldStart = Date()
    let tokens = await tokenSource.sample()
    let coldMs = Int(Date().timeIntervalSince(coldStart) * 1000)
    let warmStart = Date()
    _ = await tokenSource.sample()
    let warmMs = Int(Date().timeIntervalSince(warmStart) * 1000)
    func totals(_ value: TokenTotals) -> [String: Any] {
        ["newInput": value.newInput, "cached": value.cached, "output": value.output]
    }
    report["tokens"] = [
        "day": tokens.day, "codex": totals(tokens.codex), "claude": totals(tokens.claude),
        "codexProjects": tokens.codexProjects.map { ["project": $0.project, "withoutCache": $0.totals.withoutCache] as [String: Any] },
        "claudeProjects": tokens.claudeProjects.map { ["project": $0.project, "withoutCache": $0.totals.withoutCache] as [String: Any] },
        "contexts": tokens.contexts.map { ["id": String($0.key.prefix(8)), "used": $0.value.used, "window": $0.value.window as Any? ?? NSNull()] as [String: Any] },
        "coldMilliseconds": coldMs, "warmMilliseconds": warmMs
    ] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else if CommandLine.arguments.contains("--notify-test") {
    await Notifier.selfTest()
} else if let flag = CommandLine.arguments.firstIndex(of: "--make-icon"), flag + 1 < CommandLine.arguments.count {
    try IconArt.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
} else if let flag = CommandLine.arguments.firstIndex(of: "--make-glyph"), flag + 1 < CommandLine.arguments.count {
    // Preview of the menu-bar glyph on light and dark strips, scaled up 8x.
    let glyph = IconArt.glyph(pixels: 44, color: CGColor(gray: 0, alpha: 1))!
    let white = IconArt.glyph(pixels: 44, color: CGColor(gray: 1, alpha: 1))!
    let ctx = CGContext(data: nil, width: 880, height: 352, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 440, height: 352))
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 440, y: 0, width: 440, height: 352))
    ctx.draw(glyph, in: CGRect(x: 44, y: 0, width: 352, height: 352))
    ctx.draw(white, in: CGRect(x: 484, y: 0, width: 352, height: 352))
    let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
} else if let flag = CommandLine.arguments.firstIndex(of: "--make-badges"), flag + 1 < CommandLine.arguments.count {
    // Preview strip of the notification thumbnails, one per kind.
    let styles: [Notifier.Style] = [.finished, .waiting, .longRunning, .context, .budget]
    let strip = NSImage(size: NSSize(width: 160 * styles.count + 20 * (styles.count + 1), height: 200))
    strip.lockFocus()
    NSColor(white: 0.96, alpha: 1).setFill()
    NSRect(origin: .zero, size: strip.size).fill()
    for (index, style) in styles.enumerated() {
        if let data = IconArt.badgePNG(symbol: style.symbol, color: style.color), let badge = NSImage(data: data) {
            badge.draw(in: NSRect(x: 20 + index * 180, y: 20, width: 160, height: 160))
        }
    }
    strip.unlockFocus()
    if let tiff = strip.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    }
} else if CommandLine.arguments.contains("--keychain-selftest") {
    // Round trip with a throw-away service name; the real API key entry is never touched.
    let service = "com.zhengjl.codexstatus.llm.selftest"
    let wrote = KeychainStore.write("dummy-value-1", service: service)
    let updated = KeychainStore.write("dummy-value-2", service: service)
    let read = KeychainStore.read(service: service)
    let deleted = KeychainStore.delete(service: service)
    let gone = KeychainStore.read(service: service) == nil
    print("write:", wrote, "update:", updated, "read-back-ok:", read == "dummy-value-2", "delete:", deleted, "gone:", gone)
} else if CommandLine.arguments.contains("--summarize-now") {
    // Headless run for testing and future scheduling. Configuration comes only from the environment:
    // CODEX_STATUS_LLM_URL / _MODEL / _KEY / _FORMAT (openAI|anthropic) and optionally CODEX_STATUS_SUPPORT_DIR.
    let env = ProcessInfo.processInfo.environment
    guard let url = env["CODEX_STATUS_LLM_URL"], let model = env["CODEX_STATUS_LLM_MODEL"], let key = env["CODEX_STATUS_LLM_KEY"] else {
        print("set CODEX_STATUS_LLM_URL, CODEX_STATUS_LLM_MODEL and CODEX_STATUS_LLM_KEY"); exit(2)
    }
    let support = URL(fileURLWithPath: env["CODEX_STATUS_SUPPORT_DIR"]
        ?? NSString(string: "~/Library/Application Support/Codex Status").expandingTildeInPath)
    let summarizer = DailySummarizer(supportDirectory: support)
    guard let plan = summarizer.prepare() else { print("nothing to summarise today"); exit(0) }
    let started = Date()
    do {
        let output = try await summarizer.run(plan, config: ModelConfig(
            format: APIFormat(rawValue: env["CODEX_STATUS_LLM_FORMAT"] ?? "") ?? .openAI, endpoint: url, model: model, apiKey: key))
        print("journal: \(output.journalURL.path)\nlessons: \(output.lessonsURL?.path ?? "unchanged")\nseconds: \(Int(Date().timeIntervalSince(started)))")
    } catch { print("failed: \(error.localizedDescription)"); exit(1) }
} else if CommandLine.arguments.contains("--summarize-plan") {
    // Dry run: statistics only. Nothing is sent anywhere and no conversation text is printed.
    let transcripts = TranscriptExtractor().extract(dayKey: DailyStats.dayKey(Date()))
    let summarizer = DailySummarizer(supportDirectory: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Codex Status").expandingTildeInPath))
    let plan = summarizer.prepare()
    var report: [String: Any] = ["sessions": transcripts.count]
    report["perSession"] = transcripts.map { session -> [String: Any] in
        let users = session.messages.filter { $0.role == .user }
        let assistants = session.messages.filter { $0.role == .assistant }
        let noisy = session.messages.filter { $0.text.hasPrefix("<") || $0.text.hasPrefix("#") }.count
        return ["provider": session.provider, "project": session.project ?? "-", "user": users.count, "assistant": assistants.count,
                "userChars": users.reduce(0) { $0 + $1.text.count }, "assistantChars": assistants.reduce(0) { $0 + $1.text.count },
                "startingWithAngleOrHash": noisy]
    }
    if let plan {
        report["plan"] = ["claudeSessions": plan.claudeSessions, "codexSessions": plan.codexSessions, "messages": plan.prompt.messages,
                          "promptChars": plan.prompt.chars, "estimatedTokens": plan.estimatedTokens, "redactions": plan.redactions]
    } else { report["plan"] = "nothing to summarise" }
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} else if CommandLine.arguments.contains("--dump-report") {
    // Prints today's report exactly as "复制今日日报" would copy it.
    let tokens = await TokenUsageSource().sample()
    print(makeDailyReport(log: HistoryStore().log, tokens: tokens, now: Date()) ?? "(今天还没有可写进日报的内容)")
} else if CommandLine.arguments.contains("--health") {
    runMenuApplication(health: true)
} else if CommandLine.arguments.contains("--dump-menu") {
    runMenuApplication(dumpMenu: true)
} else {
    runMenuApplication()
}
