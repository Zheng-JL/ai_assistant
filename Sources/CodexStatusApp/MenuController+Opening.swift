import AppKit
import CodexStatusCore

// Opening Codex and Claude sessions and apps.
extension MenuController {
    @objc func openSession(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        openTarget(provider: parts[0], id: parts[1])
    }

    func openTarget(provider: String, id: String) {
        if provider == "claude" { openClaudeSession(id) }
        else if UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)") { openCodexApplication(url) }
    }

    /// Jumps to one Claude Code session; falls back to just opening Claude when the ID is unusable.
    func openClaudeSession(_ id: String?) {
        guard let url = claudeSessionURL(id), let applicationURL = claudeApplication()?.bundleURL ??
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            openClaude()
            return
        }
        openingError = nil
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: .init()) { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.showOpenError("无法打开 Claude 会话") } }
        }
    }

    @objc func openCodex() { openCodexApplication(nil) }

    @objc func openClaude() {
        guard let url = claudeApplication()?.bundleURL ??
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            openingError = "未找到 Claude 应用"
            if !tracking { rebuildMenu() }
            return
        }
        openingError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if error != nil {
                Task { @MainActor in
                    self?.openingError = "无法打开 Claude"
                    if self?.tracking == false { self?.rebuildMenu() }
                }
            }
        }
    }

    func openCodexApplication(_ threadURL: URL?) {
        guard let applicationURL = codexApplication()?.bundleURL ??
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            openingError = "未找到 Codex 应用"
            rebuildMenu()
            return
        }
        openingError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        if let threadURL {
            NSWorkspace.shared.open([threadURL], withApplicationAt: applicationURL, configuration: configuration) { [weak self] _, error in
                if error != nil { Task { @MainActor in self?.showOpenError("无法打开 Codex 会话") } }
            }
        } else {
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
                if error != nil { Task { @MainActor in self?.showOpenError("无法打开 Codex") } }
            }
        }
    }

    func showOpenError(_ message: String) {
        openingError = message
        if !tracking { rebuildMenu() }
    }
}
