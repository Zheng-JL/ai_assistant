import CodexStatusCore
import Foundation

/// Prompt templates live in a plain text file the user edits; it is created with examples on first use.
struct TemplateStore {
    let fileURL: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Status", isDirectory: true)) {
        fileURL = directory.appendingPathComponent("prompts.md")
    }

    /// Creates the file with defaults if missing; never overwrites an existing one.
    @discardableResult
    func seedIfNeeded() -> Bool {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try defaultPromptTemplateText.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    func append(title: String, body: String) -> Bool {
        seedIfNeeded()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let updated = insertingTemplate(into: text, title: title, body: body) else { return false }
        return (try? updated.write(to: fileURL, atomically: true, encoding: .utf8)) != nil
    }

    func load() -> [PromptTemplate] {
        guard let data = try? Data(contentsOf: fileURL), data.count <= 512 * 1024,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parsePromptTemplates(text)
    }
}
