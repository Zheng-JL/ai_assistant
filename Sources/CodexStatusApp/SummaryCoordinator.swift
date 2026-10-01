import AppKit
import CodexStatusCore

/// The "AI 总结" feature: settings dialog, send confirmation, running a summary, and opening the results.
/// Nothing is read or sent until the user chooses "现在总结今天…" and confirms.
@MainActor
final class SummaryCoordinator: NSObject {
    private let summarizer: DailySummarizer
    private let flash: (String, TimeInterval) -> Void
    private let clearFlash: () -> Void
    private var running = false

    init(flash: @escaping (String, TimeInterval) -> Void, clearFlash: @escaping () -> Void) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Status", isDirectory: true)
        summarizer = DailySummarizer(supportDirectory: support)
        self.flash = flash
        self.clearFlash = clearFlash
        super.init()
    }

    // MARK: Menu

    func menuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "AI 总结与踩坑清单", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let day = DailyStats.dayKey(Date())
        let hasJournal = FileManager.default.fileExists(atPath: summarizer.journalURL(dayKey: day).path)
        let hasLessons = FileManager.default.fileExists(atPath: summarizer.lessonsURL.path)
        add(running ? "正在总结…" : "现在总结今天…", #selector(summarizeNow), enabled: !running)
        menu.addItem(.separator())
        add("查看今日总结", #selector(openJournal), enabled: hasJournal)
        add("查看踩坑清单", #selector(openLessons), enabled: hasLessons)
        add("复制踩坑清单（可粘进开局）", #selector(copyLessons), enabled: hasLessons)
        menu.addItem(.separator())
        add("总结设置…", #selector(showSettings))
        add("测试连接", #selector(testConnection))
        parent.submenu = menu
        return parent
    }

    // MARK: Actions

    @objc private func openJournal() {
        NSWorkspace.shared.open(summarizer.journalURL(dayKey: DailyStats.dayKey(Date())))
    }

    @objc private func openLessons() { NSWorkspace.shared.open(summarizer.lessonsURL) }

    @objc private func copyLessons() {
        let lessons = summarizer.readLessons().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lessons.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("以下是我之前踩过的坑，这次请避免：\n\(lessons)", forType: .string)
        flash("踩坑清单已复制 ✓", 2)
    }

    @objc private func showSettings() { _ = editSettings() }

    @objc private func testConnection() {
        guard let config = currentConfig() else { _ = editSettings(); return }
        flash("正在测试连接…", 600)
        Task { [weak self] in
            let message: String
            do {
                let reply = try await ModelClient().complete(config: config, system: "Reply with the single word OK.",
                                                             user: "ping", maxTokens: 16)
                message = "连接成功。模型回复：\(reply.prefix(80))"
            } catch {
                message = "连接失败：\(error.localizedDescription)"
            }
            guard let self else { return }
            self.clearFlash()
            self.showMessage(title: "测试连接", text: message)
        }
    }

    @objc private func summarizeNow() {
        guard !running else { return }
        guard let config = currentConfig() else { _ = editSettings(); return }
        let settings = SummarySettings.load()
        running = true
        flash("正在整理今天的对话…", 600)
        Task { [weak self, summarizer] in
            let plan = await Task.detached { summarizer.prepare(maxChars: settings.maxChars) }.value
            guard let self else { return }
            guard let plan else {
                self.finish("今天还没有可以总结的对话")
                return
            }
            guard self.confirmSend(plan: plan, settings: settings) else { self.finish(nil); return }
            self.flash("AI 正在总结…", 900)
            do {
                let output = try await summarizer.run(plan, config: config)
                self.finish("总结完成 ✓")
                NSWorkspace.shared.open(output.journalURL)
            } catch {
                self.finish(nil)
                self.showMessage(title: "总结失败", text: error.localizedDescription)
            }
        }
    }

    private func finish(_ message: String?) {
        running = false
        clearFlash()
        if let message { flash(message, 3) }
    }

    // MARK: Dialogs

    private func currentConfig() -> ModelConfig? {
        let settings = SummarySettings.load()
        guard settings.isComplete, let key = KeychainStore.read(), !key.isEmpty else { return nil }
        return ModelConfig(format: settings.format, endpoint: settings.endpoint, model: settings.model, apiKey: key)
    }

    private func confirmSend(plan: SummaryPlan, settings: SummarySettings) -> Bool {
        let host = settings.host ?? "未知地址"
        if settings.confirmedHost == host { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "将把今天的对话文字发送到 \(host)"
        alert.informativeText = """
        \(plan.claudeSessions) 个 Claude 会话、\(plan.codexSessions) 个 Codex 会话，共 \(plan.prompt.messages) 条消息，\
        约 \(plan.prompt.chars) 字符（约 \(plan.estimatedTokens) tokens，会消耗该接口的额度）。

        已自动隐藏 \(plan.redactions) 处疑似密钥（尽力而为，不保证完全）。不会发送工具输出、命令结果、文件内容和隐藏的推理过程。
        """
        alert.addButton(withTitle: "发送并总结")
        alert.addButton(withTitle: "取消")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "以后向 \(host) 发送时不再询问"
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            var updated = settings
            updated.confirmedHost = host
            updated.save()
        }
        return true
    }

    /// Returns true when the user saved.
    private func editSettings() -> Bool {
        var settings = SummarySettings.load()
        let hasKey = (KeychainStore.read() ?? "").isEmpty == false
        NSApp.activate(ignoringOtherApps: true)

        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: APIFormat.allCases.map(\.label))
        format.selectItem(at: APIFormat.allCases.firstIndex(of: settings.format) ?? 0)
        let endpoint = NSTextField(string: settings.endpoint)
        endpoint.placeholderString = "https://api.example.com/v1"
        let model = NSTextField(string: settings.model)
        model.placeholderString = "例如 gpt-4o 或 claude-sonnet-4-5"
        let key = NSSecureTextField(string: "")
        key.placeholderString = hasKey ? "已保存（留空则不修改）" : "sk-…（只保存在系统钥匙串）"

        func row(_ title: String, _ field: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let stack = NSStackView(views: [label, field])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let form = NSStackView(views: [row("接口格式", format), row("请求地址", endpoint), row("模型名称", model), row("API Key", key)])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.frame = NSRect(x: 0, y: 0, width: 390, height: 140)

        let alert = NSAlert()
        alert.messageText = "AI 总结设置"
        alert.informativeText = "请求地址可以填完整路径或只填到 /v1。远程地址必须是 https，本机模型（localhost）可用 http。Key 保存在系统钥匙串，不会写进任何文件。"
        alert.accessoryView = form
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = endpoint
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        settings.format = APIFormat.allCases[max(0, format.indexOfSelectedItem)]
        settings.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !settings.endpoint.isEmpty {
            do { _ = try ModelClient.requestURL(for: ModelConfig(format: settings.format, endpoint: settings.endpoint, model: "-", apiKey: "-")) }
            catch {
                self.showMessage(title: "没有保存", text: error.localizedDescription)
                return false
            }
        }
        // A different destination must be confirmed again before anything is sent to it.
        if settings.host != SummarySettings.load().host { settings.confirmedHost = nil }
        settings.save()
        let typedKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty, !KeychainStore.write(typedKey) {
            showMessage(title: "Key 没有保存成功", text: "无法写入系统钥匙串。")
            return false
        }
        flash("设置已保存 ✓", 2)
        return true
    }

    private func showMessage(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
