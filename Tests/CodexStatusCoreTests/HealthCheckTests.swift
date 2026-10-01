import XCTest
@testable import CodexStatusCore

final class HealthCheckTests: XCTestCase {
    private let home = "/Users/me"
    private func report(_ input: HealthInputs) -> [String: HealthItem] {
        Dictionary(uniqueKeysWithValues: buildHealthReport(input, home: home).map { ($0.name, $0) })
    }
    private var healthy: HealthInputs { HealthInputs(version: "0.2.0", installedPath: "/Users/me/Applications/搭子.app") }

    func testEverythingHealthyIsAllOkOrOff() {
        let items = buildHealthReport(healthy, home: home)
        XCTAssertTrue(items.allSatisfy { $0.level == .ok || $0.level == .off }, "\(items)")
        XCTAssertEqual(report(healthy)["AI 总结"]?.level, .off)
    }

    func testInstallLocationAndStaleRegistrationsAreFlagged() {
        var input = healthy
        input.installedPath = "/private/tmp/codex-status-package.X/搭子.app"
        input.otherRegistrations = ["/private/tmp/a.app", "/private/tmp/b.app", "/private/tmp/c.app", "/private/tmp/d.app"]
        let items = report(input)
        XCTAssertEqual(items["安装位置"]?.level, .warning)
        XCTAssertEqual(items["系统登记"]?.level, .warning)
        XCTAssertTrue(items["系统登记"]!.detail.contains("没有应用图标"))
        XCTAssertFalse(items["系统登记"]!.detail.contains("d.app"))      // only the first three are listed
        XCTAssertEqual(report(HealthInputs(installedPath: "/Applications/搭子.app"))["安装位置"]?.level, .ok)
    }

    func testNotificationStates() {
        func level(_ auth: Int?, on: Bool = true, muted: Bool = false) -> HealthItem.Level {
            var input = healthy; input.notificationAuthorization = auth; input.notificationsOn = on; input.muted = muted
            return report(input)["通知"]!.level
        }
        XCTAssertEqual(level(2), .ok)
        XCTAssertEqual(level(2, on: false), .warning)
        XCTAssertEqual(level(2, muted: true), .warning)
        XCTAssertEqual(level(1), .failure)
        XCTAssertEqual(level(0), .warning)
        XCTAssertEqual(level(nil), .warning)
    }

    func testSourceStates() {
        var input = healthy
        input.codexAppRunning = false
        XCTAssertEqual(report(input)["Codex"]?.level, .off)
        input.codexAppRunning = true; input.codexDataFound = false
        XCTAssertEqual(report(input)["Codex"]?.level, .failure)
        input.codexDataFound = true; input.codexRunningKnown = false
        XCTAssertEqual(report(input)["Codex"]?.level, .warning)
        input.claudeNotice = "Claude 版本 9.9.9 未经验证"
        XCTAssertEqual(report(input)["Claude"]?.level, .warning)
        XCTAssertTrue(report(input)["Claude"]!.detail.contains("9.9.9"))
    }

    func testSummaryConfiguration() {
        var input = healthy
        input.summaryEndpointHost = "api.example.com"
        XCTAssertEqual(report(input)["AI 总结"]?.level, .warning)
        input.summaryKeyStored = true
        XCTAssertEqual(report(input)["AI 总结"]?.level, .ok)
    }

    func testFormattingAndRegistrationParsing() {
        let text = formatHealthReport(buildHealthReport(healthy, home: home), version: "0.2.0")
        XCTAssertTrue(text.hasPrefix("搭子 0.2.0 运行状况"))
        XCTAssertTrue(text.contains("✓ 通知：权限正常"))
        let divider = "\n--------------------------------------------------------------------------------\n"
        let dump = ["path: /Applications/Other.app (0x1)\nidentifier: com.other.app",
                    "path: /Users/me/Applications/搭子.app (0x2)\nidentifier: com.zhengjl.codexstatus",
                    "name: x\npath: /private/tmp/old/Codex Status.app (0xab12)\nidentifier:         com.zhengjl.codexstatus (0x9)",
                    "path: /Applications/Similar.app (0x3)\nidentifier: com.zhengjl.codexstatus.helper"].joined(separator: divider)
        XCTAssertEqual(registeredAppPaths(bundleID: "com.zhengjl.codexstatus", dump: dump),
                       ["/Users/me/Applications/搭子.app", "/private/tmp/old/Codex Status.app"])
    }
}
