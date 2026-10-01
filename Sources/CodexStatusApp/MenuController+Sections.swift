import AppKit
import CodexStatusCore

// Menu sections: groups, labels and shared row helpers.
extension MenuController {
    func addTokenGroup() {
        guard let report = tokens else { return }
        menu.addItem(.separator())
        addLabel("今日 Token（不含缓存）", image: "number")
        for (name, totals, projects) in [("Codex", report.codex, report.codexProjects),
                                         ("Claude", report.claude, report.claudeProjects)] {
            let row = NSMenuItem(title: "\(name)  \(formatTokens(totals.withoutCache))", action: nil, keyEquivalent: "")
            row.image = symbol(name == "Codex" ? "chevron.left.forwardslash.chevron.right" : "sparkles")
            guard totals.all > 0 else { row.isEnabled = false; menu.addItem(row); continue }
            let submenu = NSMenu()
            for (label, value) in [("新输入", totals.newInput), ("输出", totals.output), ("缓存命中", totals.cached)] {
                let line = NSMenuItem(title: "\(label)  \(formatTokens(value))", action: nil, keyEquivalent: "")
                line.isEnabled = false
                submenu.addItem(line)
            }
            if !projects.isEmpty {
                submenu.addItem(.separator())
                let header = NSMenuItem(title: "按项目", action: nil, keyEquivalent: "")
                header.isEnabled = false
                submenu.addItem(header)
                for project in projects {
                    let line = NSMenuItem(title: "\(project.project)  \(formatTokens(project.totals.withoutCache))",
                                          action: nil, keyEquivalent: "")
                    line.isEnabled = false
                    submenu.addItem(line)
                }
            }
            row.submenu = submenu
            menu.addItem(row)
        }
        let recent = tokenHistory.history.recent(7, now: Date())
        if recent.count > 1 {
            let trend = NSMenuItem(title: "近 7 天", action: nil, keyEquivalent: "")
            trend.image = symbol("chart.bar")
            let submenu = NSMenu()
            for (index, entry) in recent.enumerated() {
                let label = index == 0 ? "今天" : String(entry.day.dropFirst(5))
                let line = NSMenuItem(
                    title: "\(label)  Cx \(formatTokens(entry.tokens.codex.withoutCache))  ·  Cl \(formatTokens(entry.tokens.claude.withoutCache))",
                    action: nil, keyEquivalent: "")
                line.isEnabled = false
                submenu.addItem(line)
            }
            trend.submenu = submenu
            menu.addItem(trend)
        }
    }

    @objc func copyDailyReport() {
        guard let report = makeDailyReport(log: history.log, tokens: tokens, now: Date()) else {
            flashTitle("今天还没有可写进日报的内容")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        flashTitle("日报已复制 ✓")
    }

    func addHistoryGroup() {
        let row = NSMenuItem(title: "最近完成  \(history.records.count)", action: nil, keyEquivalent: "")
        row.image = symbol("clock.arrow.circlepath")
        menu.addItem(.separator())
        if let summary = history.stats.summary(now: Date()) { addLabel(summary, image: "chart.bar") }
        if history.records.isEmpty { row.isEnabled = false; menu.addItem(row); return }
        let submenu = NSMenu()
        let now = Date()
        for record in history.records {
            var title = record.title.count > 34 ? String(record.title.prefix(34)) + "…" : record.title
            var parts = [record.provider == "codex" ? "Cx" : "Cl"]
            if let project = record.project { parts.append(project) }
            parts.append(formatAgo(now.timeIntervalSince(record.finishedAt)))
            if let duration = record.duration { parts.append("用时 \(formatElapsed(duration))") }
            title += "  ·  " + parts.joined(separator: " · ")
            let child = NSMenuItem(title: title, action: #selector(openHistory(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = "\(record.provider)|\(record.provider == "claude" ? (record.openID ?? record.sessionID) : record.sessionID)"
            child.toolTip = record.title
            submenu.addItem(child)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "清空历史", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)
        row.submenu = submenu
        menu.addItem(row)
    }

    @objc func openHistory(_ sender: NSMenuItem) { openSession(sender) }

    @objc func clearHistory() { history.clear(); rebuildMenu() }

    func addNotificationItems() {
        let toggle = NSMenuItem(title: "完成与等待通知", action: #selector(toggleNotifications), keyEquivalent: "")
        toggle.target = self
        toggle.state = notifier.isEnabled ? .on : .off
        menu.addItem(toggle)
        let muted = notifier.mutedUntil
        let mute = NSMenuItem(title: muted.map { "取消静音（至 \($0.formatted(date: .omitted, time: .shortened))）" } ?? "静音 1 小时",
                              action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.isEnabled = notifier.isEnabled
        menu.addItem(mute)
    }

    @objc func toggleNotifications() { notifier.isEnabled.toggle(); rebuildMenu() }

    @objc func toggleMute() { notifier.toggleMute(); rebuildMenu() }

    func addLabel(_ text: String, emphasized: Bool = false, image: String? = nil) {
        let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        row.isEnabled = false
        if emphasized {
            row.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        }
        if let image { row.image = symbol(image) }
        menu.addItem(row)
    }

    enum RowDetail { case none, elapsed, ago }

    /// "上下文 82%" when the window is known (Codex), otherwise the absolute size (Claude).
    func contextLabel(for sessionID: String) -> String? {
        guard let context = tokens?.contexts[sessionID] else { return nil }
        if let fraction = context.fraction { return "上下文 \(Int((fraction * 100).rounded()))%" }
        return "上下文 \(formatTokens(context.used))"
    }

    func addGroup(_ title: String, count: Int?, sessions: [SessionStatus], image: String,
                          indicator: StatusIndicator? = nil,
                          provider: String = "codex", detail: RowDetail = .none) {
        let row = NSMenuItem(title: "\(title)  \(count.map(String.init) ?? "--")", action: nil, keyEquivalent: "")
        row.image = indicator?.image(for: count) ?? symbol(image)
        if sessions.isEmpty {
            row.isEnabled = false
        } else {
            let submenu = NSMenu()
            let now = Date()
            // Group by project folder (newest project first) once more than one project is present.
            let byProject = Dictionary(grouping: sessions, by: { $0.project ?? "" })
            let blocks = byProject.sorted {
                let left = $0.value.compactMap(\.updatedAt).max() ?? .distantPast
                let right = $1.value.compactMap(\.updatedAt).max() ?? .distantPast
                return left == right ? $0.key < $1.key : left > right
            }
            for (project, members) in blocks {
                if byProject.count > 1 {
                    let header = NSMenuItem(title: project.isEmpty ? "其他" : project, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    header.attributedTitle = NSAttributedString(string: header.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor])
                    submenu.addItem(header)
                }
                for session in members {
                    var name = session.title.count > 44 ? String(session.title.prefix(44)) + "…" : session.title
                    switch detail {
                    case .elapsed:
                        if let since = session.phaseSince { name += "  ·  \(formatElapsed(now.timeIntervalSince(since)))" }
                    case .ago:
                        if let updated = session.updatedAt { name += "  ·  \(formatAgo(now.timeIntervalSince(updated)))" }
                    case .none: break
                    }
                    if let context = contextLabel(for: session.id) { name += "  ·  \(context)" }
                    // Codex opens by thread ID; Claude needs its own `local_…` ID, which not every session has.
                    let target = provider == "claude" ? session.openID : session.id
                    let child = NSMenuItem(title: name, action: target != nil ? #selector(openSession(_:)) : nil, keyEquivalent: "")
                    if let target {
                        child.target = self
                        child.representedObject = "\(provider)|\(target)"
                    } else {
                        child.isEnabled = false
                    }
                    child.toolTip = session.project.map { "\(session.title)\n项目：\($0)" } ?? session.title
                    child.image = indicator?.image(for: 1)
                    submenu.addItem(child)
                }
            }
            row.submenu = submenu
        }
        menu.addItem(row)
    }

    func addAction(_ text: String, selector: Selector, image: String) {
        let row = NSMenuItem(title: text, action: selector, keyEquivalent: "")
        row.target = self
        row.image = symbol(image)
        menu.addItem(row)
    }

    func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        return image
    }
}
