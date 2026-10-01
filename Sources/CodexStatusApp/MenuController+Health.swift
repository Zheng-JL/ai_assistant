import AppKit
import CodexStatusCore
import UserNotifications

// 运行状况检查: gathers real facts, builds the verdict in Core, and shows it.
extension MenuController {
    func healthInputs() async -> HealthInputs {
        let bundle = Bundle.main
        let home = NSHomeDirectory()
        var input = HealthInputs()
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        input.version = "\(short)（构建 \(build)）"
        input.installedPath = bundle.bundleURL.path
        input.hasIcon = bundle.url(forResource: "AppIcon", withExtension: "icns") != nil

        if bundle.bundleURL.pathExtension == "app" {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            input.notificationAuthorization = settings.authorizationStatus.rawValue
        } else {
            input.notificationAuthorization = nil
        }
        input.notificationsOn = notifier.isEnabled
        input.muted = notifier.mutedUntil != nil

        let manager = FileManager.default
        input.codexAppRunning = snapshot.appIsRunning
        input.codexDataFound = manager.fileExists(atPath: home + "/.codex/session_index.jsonl")
        input.codexRunningKnown = snapshot.runningCount != nil
        input.codexNotice = snapshot.notice
        input.claudeAppRunning = claudeSnapshot.appIsRunning
        input.claudeDataFound = manager.fileExists(atPath: home + "/.claude/sessions")
        input.claudeRunningKnown = claudeSnapshot.runningCount != nil
        input.claudeNotice = claudeSnapshot.notice
        input.tokenStatsOK = tokens != nil

        let summarySettings = SummarySettings.load()
        input.summaryEndpointHost = summarySettings.endpoint.isEmpty ? nil : (summarySettings.host ?? summarySettings.endpoint)
        input.summaryKeyStored = KeychainStore.exists()
        input.hotKeysRegistered = hotKeyRegistered && templateHotKeyRegistered

        let id = bundle.bundleIdentifier ?? "com.zhengjl.codexstatus"
        let current = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let dump = await Task.detached { Self.launchServicesDump() }.value
        input.otherRegistrations = registeredAppPaths(bundleID: id, dump: dump).filter {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path != current
        }
        return input
    }

    /// `lsregister -dump` is large and takes a moment, so it only runs when the check is requested.
    nonisolated static func launchServicesDump() -> String {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-dump"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @objc func showHealth() {
        flashTitle("正在检查…", seconds: 8)
        Task { [weak self] in
            guard let self else { return }
            let input = await self.healthInputs()
            let text = formatHealthReport(buildHealthReport(input), version: input.version)
            self.clearFlash()
            self.presentHealth(text)
        }
    }

    private func presentHealth(_ report: String) {
        NSApp.activate(ignoringOtherApps: true)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 250))
        textView.string = report
        textView.isEditable = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "运行状况"
        alert.informativeText = "✓ 正常  ⚠ 需要留意  ✗ 有问题  – 未启用"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "复制报告")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            flashTitle("报告已复制 ✓")
        }
    }
}
