import Foundation

public struct BuiltPrompt: Sendable, Equatable {
    public let system: String
    public let user: String
    public let sessions: Int
    public let messages: Int
    /// Total characters that would be sent (system + user).
    public var chars: Int { system.count + user.count }
}

public let journalMarker = "===日报==="
public let lessonsMarker = "===踩坑清单==="

private let summarySystemPrompt = """
你是我的工程复盘助手。我会给你今天与 AI 编程助手（Claude Code、Codex）的对话摘录，以及我已有的“踩坑清单”。请只依据对话内容复盘，不要编造；没有就写“无”。不要输出任何密钥、令牌或密码。

请严格按下面的格式输出两部分，分隔行必须单独成行、原样输出：

===日报===
# 日期 AI 编程日报
## 今天做了什么（按项目，每项一两句话）
## 经验（可复用的做法，说清楚在什么情况下有效）
## 踩坑（每条写：现象 → 原因 → 以后怎么避免）
## 明天可以改进（最多 3 条，要具体、可执行）
===踩坑清单===
把“已有踩坑清单”和今天新增的踩坑合并去重，输出更新后的完整清单：最多 30 条，按重要性排序，每条一行，格式：
- [项目名或“通用”] 一句话规则 —— 原因
合并时保留仍然有价值的旧条目，删除重复或已过时的，把相近的合并成一条。
"""

private func shorten(_ text: String, to cap: Int) -> String {
    guard text.count > cap else { return text }
    let head = Int(Double(cap) * 0.7)
    let tail = cap - head
    return String(text.prefix(head)) + " …（省略）… " + String(text.suffix(tail))
}

private func clockTime(_ date: Date?) -> String {
    guard let date else { return "" }
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

private func render(_ session: SessionTranscript, userCap: Int, assistantCap: Int, omitted: Set<Int> = []) -> String {
    let name = session.provider == "claude" ? "Claude" : "Codex"
    let span = [session.messages.first?.at, session.messages.last?.at].map(clockTime).joined(separator: "–")
    var lines = ["### [\(name)] 项目：\(session.project ?? "未知") · 会话 \(session.sessionID.prefix(8)) · \(span) · \(session.messages.count) 条"]
    var skipped = 0
    for (index, message) in session.messages.enumerated() {
        if omitted.contains(index) { skipped += 1; continue }
        if skipped > 0 { lines.append("（中间省略 \(skipped) 条）"); skipped = 0 }
        let who = message.role == .user ? "我" : "AI"
        lines.append("\(who)：" + shorten(message.text, to: message.role == .user ? userCap : assistantCap))
    }
    if skipped > 0 { lines.append("（中间省略 \(skipped) 条）") }
    return lines.joined(separator: "\n")
}

/// Fits one session into `allotment` characters: shorten long messages first, then drop the middle.
func fit(_ session: SessionTranscript, allotment: Int) -> String {
    for (userCap, assistantCap) in [(1200, 700), (600, 350), (300, 150), (150, 60)] {
        let text = render(session, userCap: userCap, assistantCap: assistantCap)
        if text.count <= allotment { return text }
    }
    var omitted = Set<Int>()
    var text = render(session, userCap: 150, assistantCap: 60)
    var candidates = Array(session.messages.indices.dropFirst(2).dropLast(2))
    while text.count > allotment, !candidates.isEmpty {
        // Drop from the middle outward, assistant messages before the user's own words.
        let middle = candidates.count / 2
        let pick = candidates.indices.sorted { abs($0 - middle) < abs($1 - middle) }
            .first { session.messages[candidates[$0]].role == .assistant } ?? middle
        omitted.insert(candidates.remove(at: pick))
        text = render(session, userCap: 150, assistantCap: 60, omitted: omitted)
    }
    return text
}

public func buildSummaryPrompt(transcripts: [SessionTranscript], existingLessons: String, dayKey: String,
                               maxChars: Int) -> BuiltPrompt {
    let lessons = existingLessons.trimmingCharacters(in: .whitespacesAndNewlines)
    let lessonsBlock = "## 已有踩坑清单\n" + (lessons.isEmpty ? "（暂无）" : String(lessons.prefix(8_000)))
    let header = "日期：\(dayKey)\n\n" + lessonsBlock + "\n\n## 今天的对话摘录\n"
    let budget = max(2_000, maxChars - summarySystemPrompt.count - header.count)

    let natural = transcripts.map { render($0, userCap: 1200, assistantCap: 700) }
    let total = natural.reduce(0) { $0 + $1.count }
    var blocks = natural
    if total > budget {
        blocks = transcripts.enumerated().map { index, session in
            let share = Double(natural[index].count) / Double(max(1, total))
            return fit(session, allotment: max(1_500, Int(Double(budget) * share)))
        }
    }
    let body = blocks.isEmpty ? "（今天没有可总结的对话）" : blocks.joined(separator: "\n\n")
    return BuiltPrompt(system: summarySystemPrompt, user: header + body, sessions: transcripts.count,
                       messages: transcripts.reduce(0) { $0 + $1.messages.count })
}

/// Splits the model's reply into the daily report and the updated lessons list.
public func parseSummaryReply(_ reply: String) -> (journal: String, lessons: String?) {
    func unfenced(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let lines = reply.components(separatedBy: "\n")
    let journalAt = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == journalMarker }
    let lessonsAt = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == lessonsMarker }
    guard let lessonsAt else {
        let from = journalAt.map { $0 + 1 } ?? 0
        return (unfenced(lines[from...].joined(separator: "\n")), nil)
    }
    let journalStart = journalAt.map { $0 + 1 } ?? 0
    let journal = journalStart < lessonsAt ? lines[journalStart..<lessonsAt].joined(separator: "\n") : ""
    let lessons = unfenced(lines[(lessonsAt + 1)...].joined(separator: "\n"))
    return (unfenced(journal), lessons.isEmpty ? nil : lessons)
}
