import XCTest
@testable import CodexStatusCore

final class NotificationCopyTests: XCTestCase {
    private func event(_ kind: StatusEvent.Kind, project: String? = "my-app", duration: TimeInterval? = 125) -> StatusEvent {
        .init(kind: kind, sessionID: "a", title: "修复登录", project: project, occurredAt: Date(), duration: duration)
    }

    func testFinishedSplitsIntoTitleSubtitleBody() {
        XCTAssertEqual(notificationCopy(for: event(.finished), provider: "Claude"),
                       NotificationCopy(title: "Claude 完成了", subtitle: "my-app · 用时 2 分钟", body: "修复登录"))
    }

    func testMissingProjectOrDurationLeavesNoDanglingSeparator() {
        XCTAssertEqual(notificationCopy(for: event(.finished, project: nil, duration: nil), provider: "Codex").subtitle, "")
        XCTAssertEqual(notificationCopy(for: event(.finished, project: nil), provider: "Codex").subtitle, "用时 2 分钟")
        XCTAssertEqual(notificationCopy(for: event(.needsInput, duration: nil), provider: "Codex").subtitle, "my-app")
    }

    func testWaitingAndLongRunningWording() {
        XCTAssertEqual(notificationCopy(for: event(.needsInput), provider: "Codex").title, "Codex 在等你")
        let long = notificationCopy(for: event(.longRunning, duration: 1800), provider: "Claude")
        XCTAssertEqual(long.title, "Claude 已运行 30 分钟")
        XCTAssertEqual(long.subtitle, "my-app · 可能需要看一眼")
        XCTAssertEqual(notificationCopy(for: event(.longRunning, duration: nil), provider: "Claude").title, "Claude 运行较久")
    }

    func testContextAndBudgetWording() {
        let alert = ContextAlert(sessionID: "a", title: "重构", project: "p", fraction: 0.846)
        XCTAssertEqual(notificationCopy(for: alert, provider: "Codex").title, "Codex 上下文已用 85%")
        XCTAssertEqual(notificationCopy(for: alert, provider: "Codex").subtitle, "p · 建议先写交接摘要再换新会话")
        let budget = budgetNotificationCopy(total: 1_200_000, budget: 1_000_000, codex: 200_000, claude: 1_000_000)
        XCTAssertEqual(budget.subtitle, "新输入+输出 1.2M / 预算 1.0M")
        XCTAssertEqual(budget.body, "Codex 200.0K · Claude 1.0M")
    }
}
