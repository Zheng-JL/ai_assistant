import AppKit
import CodexStatusCore

// Prompt templates: the menu, copying with variables, saving from the clipboard.
extension MenuController {
    func addTemplateGroup() {
        let row = NSMenuItem(title: "常用提示词", action: nil, keyEquivalent: "")
        row.image = symbol("text.quote")
        let submenu = NSMenu()
        fillTemplateMenu(submenu)
        row.submenu = submenu
        menu.addItem(row)
    }

    /// Builds the template list into `target`; shared by the main menu and the template-only popup.
    func fillTemplateMenu(_ target: NSMenu) {
        let all = templates.load()
        func entry(_ template: PromptTemplate) -> NSMenuItem {
            let child = NSMenuItem(title: template.title, action: #selector(copyTemplate(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = template.body
            child.toolTip = String(template.body.prefix(300))
            return child
        }
        all.filter { $0.project == nil && !$0.isMore }.forEach { target.addItem(entry($0)) }
        // Project-specific templates appear only while that project has a visible session.
        for project in Set((snapshot.sessions + claudeSnapshot.sessions).compactMap(\.project)).sorted() {
            let scoped = all.filter { $0.project == project }
            guard !scoped.isEmpty else { continue }
            target.addItem(.separator())
            let header = NSMenuItem(title: "项目：\(project)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            target.addItem(header)
            scoped.forEach { target.addItem(entry($0)) }
        }
        let more = all.filter { $0.project == nil && $0.isMore }
        if !more.isEmpty {
            target.addItem(.separator())
            let moreItem = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
            let moreMenu = NSMenu()
            more.forEach { moreMenu.addItem(entry($0)) }
            moreItem.submenu = moreMenu
            target.addItem(moreItem)
        }
        if all.isEmpty {
            let empty = NSMenuItem(title: "还没有模板", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            target.addItem(empty)
        }
        target.addItem(.separator())
        let save = NSMenuItem(title: "把剪贴板存为模板…", action: #selector(saveClipboardTemplate), keyEquivalent: "")
        save.target = self
        target.addItem(save)
        let edit = NSMenuItem(title: "编辑模板文件…", action: #selector(editTemplates), keyEquivalent: "")
        edit.target = self
        target.addItem(edit)
    }

    /// Shows only the template list at the mouse pointer (global shortcut).
    func popUpTemplates() {
        let popup = NSMenu()
        fillTemplateMenu(popup)
        NSApp.activate(ignoringOtherApps: true)
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Project of the most recently active session, preferring ones that are running or waiting.
    func currentProject() -> String? {
        let candidates = (snapshot.sessions + claudeSnapshot.sessions).filter { $0.project != nil }
        let active = candidates.filter { $0.phase == .running || $0.phase == .waitingForInput }
        return (active.isEmpty ? candidates : active)
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }?.project
    }

    @objc func copyTemplate(_ sender: NSMenuItem) {
        guard let body = sender.representedObject as? String else { return }
        // The clipboard is read only for templates that use {剪贴板}.
        let clipboard = (body.contains("{剪贴板}") || body.contains("{clipboard}")) ? NSPasteboard.general.string(forType: .string) : nil
        let result = expandTemplate(body, project: currentProject(), clipboard: clipboard, now: Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        flashTitle(result.unresolved.isEmpty ? "已复制 ✓" : "已复制，\(result.unresolved.joined(separator: "")) 无内容")
    }

    @objc func saveClipboardTemplate() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            flashTitle("剪贴板里没有文字")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "把剪贴板内容存为模板"
        alert.informativeText = String(text.prefix(120)) + (text.count > 120 ? "…" : "")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "模板标题"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        flashTitle(templates.append(title: field.stringValue, body: text) ? "已保存模板 ✓" : "没有保存（标题为空或内容过长）")
    }

    @objc func editTemplates() {
        templates.seedIfNeeded()
        NSWorkspace.shared.open(templates.fileURL)
    }
}
