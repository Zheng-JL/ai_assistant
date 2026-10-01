import AppKit
import Carbon.HIToolbox
import ServiceManagement
import CodexStatusCore

@MainActor
func runMenuApplication(dumpMenu: Bool = false, health: Bool = false) {
    let application = NSApplication.shared
    let controller = MenuController()
    controller.dumpAndExit = dumpMenu
    controller.healthAndExit = health
    application.setActivationPolicy(.accessory)
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
}

@MainActor
final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    let source = LocalStatusSource()
    let claudeSource = ClaudeStatusSource()
    var snapshot = StatusSnapshot.unavailable("正在读取状态", appIsRunning: true)
    var claudeSnapshot = StatusSnapshot.unavailable("正在读取状态", appIsRunning: true)
    var timer: Timer?
    var sampling: Task<Void, Never>?
    var tracking = false
    var sleeping = false
    var generation = 0
    var openingError: String?
    /// `--dump-menu`: print the menu tree after the first sample and quit, for checking without a screen.
    var dumpAndExit = false
    /// `--health`: print the 运行状况 report after the first sample and quit.
    var healthAndExit = false
    let notifier = Notifier()
    let keepAwake = KeepAwake()
    lazy var summary = SummaryCoordinator(
        flash: { [weak self] text, seconds in self?.flashTitle(text, seconds: seconds) },
        clearFlash: { [weak self] in self?.clearFlash() })
    var codexSmoother = SnapshotSmoother()
    var claudeSmoother = SnapshotSmoother()
    let hotKey = HotKey(id: 1)
    let templateHotKey = HotKey(id: 2)
    var hotKeyRegistered = false
    var templateHotKeyRegistered = false
    var history = HistoryStore()
    let templates = TemplateStore()
    let tokenSource = TokenUsageSource()
    var tokens: TokenReport?
    var tokenHistory = TokenHistoryStore()
    var codexContextTracker = ContextAlertTracker()
    var claudeContextTracker = ContextAlertTracker()
    var copiedFlash: Task<Void, Never>?
    var flashUntil = Date.distantPast
    var codexDetector = TransitionDetector()
    var claudeDetector = TransitionDetector()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = StatusIndicator.font
        item.button?.image = IconArt.menuBarImage() ?? symbol("terminal")
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Codex 与 Claude 任务状态")
        menu.delegate = self
        item.menu = menu
        notifier.onActivate = { [weak self] provider, id in self?.openTarget(provider: provider, id: id) }
        notifier.start()
        templates.seedIfNeeded()
        hotKey.onPress = { [weak self] in self?.item.button?.performClick(nil) }
        hotKeyRegistered = hotKey.register(keyCode: UInt32(kVK_ANSI_J),
                                           modifiers: UInt32(controlKey | optionKey | cmdKey))
        templateHotKey.onPress = { [weak self] in self?.popUpTemplates() }
        templateHotKeyRegistered = templateHotKey.register(keyCode: UInt32(kVK_ANSI_K),
                                                           modifiers: UInt32(controlKey | optionKey | cmdKey))
        render()
        rebuildMenu()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.4
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        keepAwake.set(false)
        hotKey.unregister()
        templateHotKey.unregister()
        sampling?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        tracking = true
    }

    func menuDidClose(_ menu: NSMenu) { tracking = false }

    @objc func workspaceChanged() { refresh() }

    @objc func willSleep() {
        sleeping = true
        keepAwake.set(false)
        generation += 1
        sampling?.cancel()
        sampling = nil
        snapshot = .unavailable("休眠中", appIsRunning: snapshot.appIsRunning)
        claudeSnapshot = .unavailable("休眠中", appIsRunning: claudeSnapshot.appIsRunning)
        render()
    }

    @objc func didWake() {
        sleeping = false
        refresh()
    }

    @objc func refresh() {
        guard !sleeping, sampling == nil else { return }
        let currentGeneration = generation
        let application = codexApplication()
        let pid = application?.processIdentifier
        let bundleURL = application?.bundleURL
        let claude = claudeApplication()
        let claudePID = claude?.processIdentifier
        let claudeBundle = claude?.bundleURL
        sampling = Task { [weak self, source, claudeSource, tokenSource] in
            async let codexResult = source.sample(appPID: pid, appBundle: bundleURL)
            async let claudeResult = claudeSource.sample(appPID: claudePID, appBundle: claudeBundle)
            async let tokenResult = tokenSource.sample()
            let (rawCodex, rawClaude, tokenReport) = await (codexResult, claudeResult, tokenResult)
            guard !Task.isCancelled, let self, currentGeneration == self.generation else { return }
            // One-off "unknown" samples are hidden; a persistent one is still shown honestly.
            let result = self.codexSmoother.smooth(rawCodex)
            let claudeResultSnapshot = self.claudeSmoother.smooth(rawClaude)
            self.snapshot = result
            self.tokens = tokenReport
            self.tokenHistory.record(tokenReport)
            self.notifier.postContextWarning(
                self.codexContextTracker.observe(sessions: result.sessions, contexts: tokenReport.contexts,
                                                 threshold: self.notifier.contextThreshold),
                provider: "Codex", key: "codex")
            self.notifier.postContextWarning(
                self.claudeContextTracker.observe(sessions: claudeResultSnapshot.sessions, contexts: tokenReport.contexts,
                                                  threshold: self.notifier.contextThreshold),
                provider: "Claude", key: "claude")
            let spent = tokenReport.codex.withoutCache + tokenReport.claude.withoutCache
            let budget = self.notifier.dailyBudget
            if shouldAlertBudget(total: spent, budget: budget, day: tokenReport.day,
                                 alertedDay: self.notifier.budgetAlertedDay) {
                self.notifier.budgetAlertedDay = tokenReport.day
                self.notifier.postBudgetWarning(total: spent, budget: budget,
                                                codex: tokenReport.codex.withoutCache,
                                                claude: tokenReport.claude.withoutCache)
            }
            self.claudeSnapshot = claudeResultSnapshot
            self.updateKeepAwake()
            self.sampling = nil
            let now = Date()
            self.codexDetector.stuckAfter = self.notifier.stuckAfter
            self.claudeDetector.stuckAfter = self.notifier.stuckAfter
            let codexEvents = self.codexDetector.observe(result.sessions, now: now)
            let claudeEvents = self.claudeDetector.observe(claudeResultSnapshot.sessions, now: now)
            self.history.record(codexEvents, provider: "codex")
            self.history.record(claudeEvents, provider: "claude")
            self.notifier.post(codexEvents, provider: "Codex", key: "codex")
            self.notifier.post(claudeEvents, provider: "Claude", key: "claude")
            self.render()
            if !self.tracking { self.rebuildMenu() }
            if self.healthAndExit {
                Task {
                    let input = await self.healthInputs()
                    print(formatHealthReport(buildHealthReport(input), version: input.version))
                    fflush(stdout)
                    NSApplication.shared.terminate(nil)
                }
            }
            if self.dumpAndExit {
                self.rebuildMenu()
                print("菜单栏标题: \(self.item.button?.attributedTitle.string ?? "")")
                print(Self.dump(self.menu))
                fflush(stdout)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    static func dump(_ menu: NSMenu, depth: Int = 0) -> String {
        menu.items.map { entry -> String in
            let pad = String(repeating: "    ", count: depth)
            if entry.isSeparatorItem { return pad + "────────" }
            var line = pad + (entry.state == .on ? "✓ " : "") + entry.title
            if !entry.isEnabled { line += "   (灰)" }
            if let sub = entry.submenu { line += "  ▸\n" + dump(sub, depth: depth + 1) }
            return line
        }.joined(separator: "\n")
    }

    func render() {
        // Keep a short confirmation ("已复制 ✓") visible instead of overwriting it on the next refresh.
        if Date() < flashUntil { return }
        let codexWaiting = snapshot.sessions.filter { $0.phase == .waitingForInput }.count
        let claudeWaiting = claudeSnapshot.sessions.filter { $0.phase == .waitingForInput }.count
        item.button?.attributedTitle = StatusIndicator.compactTitle(
            codex: snapshot.appIsRunning ? .init(running: snapshot.runningCount, waiting: codexWaiting,
                                                 unread: snapshot.completedUnreadCount) : nil,
            claude: claudeSnapshot.appIsRunning ? .init(running: claudeSnapshot.runningCount,
                                                        waiting: claudeWaiting, unread: nil) : nil)
        let codexValue = StatusIndicator.accessibilityValue(
            running: snapshot.runningCount, unread: snapshot.completedUnreadCount, waiting: codexWaiting)
        let claudeValue = StatusIndicator.accessibilityValue(
            running: claudeSnapshot.runningCount, unread: claudeSnapshot.completedUnreadCount,
            waiting: claudeWaiting, provider: "Claude")
        item.button?.toolTip = [codexValue + (snapshot.notice.map { "；\($0)" } ?? ""),
                                claudeValue + (claudeSnapshot.notice.map { "；\($0)" } ?? "")]
            .joined(separator: "\n")
        item.button?.setAccessibilityValue(codexValue + "。" + claudeValue)
    }

    func rebuildMenu() {
        menu.removeAllItems()
        addLabel("Codex", emphasized: true)
        addLabel("本机 · \(snapshot.sampledAt.formatted(date: .omitted, time: .standard))")
        if let notice = snapshot.notice { addLabel(notice, image: "exclamationmark.triangle") }
        addGroup("运行中", count: snapshot.runningCount,
                 sessions: snapshot.sessions.filter { $0.phase == .running },
                 image: "arrow.triangle.2.circlepath", indicator: .running, detail: .elapsed)
        let waiting = snapshot.sessions.filter { $0.phase == .waitingForInput }
        if !waiting.isEmpty {
            addGroup("等待输入", count: waiting.count, sessions: waiting,
                     image: "person.crop.circle.badge.questionmark", indicator: .waiting, detail: .elapsed)
        }
        addGroup("已完成未读", count: snapshot.completedUnreadCount,
                 sessions: snapshot.sessions.filter { $0.phase == .completed && $0.isUnread },
                 image: "checkmark.circle", indicator: .unread)
        let other = snapshot.sessions.filter { [.interrupted, .failed, .unknown].contains($0.phase) }
        if !other.isEmpty { addGroup("中断或状态未知", count: other.count, sessions: other, image: "questionmark.circle") }

        menu.addItem(.separator())
        addLabel("Claude Code", emphasized: true)
        if let notice = claudeSnapshot.notice { addLabel(notice, image: "exclamationmark.triangle") }
        addGroup("运行中", count: claudeSnapshot.runningCount,
                 sessions: claudeSnapshot.sessions.filter { $0.phase == .running },
                 image: "arrow.triangle.2.circlepath", indicator: .running, provider: "claude", detail: .elapsed)
        for (phase, title, image) in [
            (SessionPhase.waitingForInput, "等待输入或审批", "person.crop.circle.badge.questionmark"),
            (.backgroundRunning, "后台命令", "terminal"),
            (.idle, "空闲", "pause.circle"),
            (.unknown, "状态未知", "questionmark.circle")
        ] {
            var sessions = claudeSnapshot.sessions.filter { $0.phase == phase }
            // Idle sessions older than a day are noise; keep the list to recently used ones.
            if phase == .idle {
                sessions = sessions.filter { Date().timeIntervalSince($0.updatedAt ?? .distantPast) < 86_400 }
            }
            if !sessions.isEmpty {
                addGroup(title, count: sessions.count, sessions: sessions, image: image,
                         indicator: phase == .waitingForInput ? .waiting : nil,
                         provider: "claude",
                         detail: phase == .waitingForInput ? .elapsed : phase == .idle ? .ago : .none)
            }
        }

        addHistoryGroup()
        addAction("复制今日日报", selector: #selector(copyDailyReport), image: "doc.on.clipboard")
        menu.addItem(summary.menuItem())
        addTokenGroup()
        addTemplateGroup()
        menu.addItem(.separator())
        if let error = openingError { addLabel(error, image: "exclamationmark.triangle") }
        if keepAwake.isActive { addLabel("正在阻止休眠（有任务在运行）", image: "moon.zzz") }
        addAction("刷新", selector: #selector(refresh), image: "arrow.clockwise")
        addAction("打开 Codex", selector: #selector(openCodex), image: "arrow.up.forward.app")
        addAction("打开 Claude", selector: #selector(openClaude), image: "arrow.up.forward.app")
        menu.addItem(.separator())
        addNotificationItems()
        addSettingsMenu()
        addAction("检查运行状况…", selector: #selector(showHealth), image: "stethoscope")
        menu.addItem(.separator())
        if hotKeyRegistered || templateHotKeyRegistered {
            addLabel([hotKeyRegistered ? "⌃⌥⌘J 呼出本菜单" : nil,
                      templateHotKeyRegistered ? "⌃⌥⌘K 提示词" : nil].compactMap { $0 }.joined(separator: "  ·  "))
        }
        addAction("退出 搭子", selector: #selector(quit), image: "power")
    }

    /// Brief message in the status bar, since menus close on click. Long-running work passes a long duration
    /// and ends it with `clearFlash()`.
    func flashTitle(_ text: String, seconds: TimeInterval = 2) {
        copiedFlash?.cancel()
        flashUntil = Date().addingTimeInterval(seconds)
        item.button?.attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: StatusIndicator.font, .foregroundColor: NSColor.labelColor])
        copiedFlash = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.05))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    func clearFlash() {
        copiedFlash?.cancel()
        flashUntil = .distantPast
        render()
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}
