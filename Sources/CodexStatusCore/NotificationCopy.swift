import Foundation

/// Wording for a notification, split so the banner reads as: what happened / where and how long / which task.
public struct NotificationCopy: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let body: String
}

private func joined(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

public func notificationCopy(for event: StatusEvent, provider: String) -> NotificationCopy {
    switch event.kind {
    case .finished:
        return .init(title: "\(provider) 完成了",
                     subtitle: joined([event.project, event.duration.map { "用时 \(formatElapsed($0))" }]),
                     body: event.title)
    case .needsInput:
        return .init(title: "\(provider) 在等你",
                     subtitle: joined([event.project, event.duration.map { "已运行 \(formatElapsed($0))" }]),
                     body: event.title)
    case .longRunning:
        return .init(title: event.duration.map { "\(provider) 已运行 \(formatElapsed($0))" } ?? "\(provider) 运行较久",
                     subtitle: joined([event.project, "可能需要看一眼"]),
                     body: event.title)
    }
}

public func notificationCopy(for alert: ContextAlert, provider: String) -> NotificationCopy {
    .init(title: "\(provider) 上下文已用 \(Int((alert.fraction * 100).rounded()))%",
          subtitle: joined([alert.project, "建议先写交接摘要再换新会话"]),
          body: alert.title)
}

public func budgetNotificationCopy(total: Int, budget: Int, codex: Int, claude: Int) -> NotificationCopy {
    .init(title: "今日 Token 超预算",
          subtitle: "新输入+输出 \(formatTokens(total)) / 预算 \(formatTokens(budget))",
          body: "Codex \(formatTokens(codex)) · Claude \(formatTokens(claude))")
}
