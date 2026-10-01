import AppKit

@MainActor
enum StatusIndicator {
    case running, waiting, unread

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    func color(for count: Int?) -> NSColor {
        guard let count, count > 0 else { return .secondaryLabelColor }
        switch self {
        case .running: return .systemGreen
        case .waiting: return .systemOrange
        case .unread: return .systemBlue
        }
    }

    func image(for count: Int?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color(for: count)])
        guard let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        dot.isTemplate = false
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            dot.draw(in: NSRect(x: 5, y: 5, width: 6, height: 6))
            return true
        }
        image.isTemplate = false
        return image
    }

    static func countLabel(_ count: Int?) -> String {
        guard let count else { return "--" }
        return count > 999 ? "999+" : String(count)
    }

    struct Counts {
        var running: Int?
        var waiting: Int
        var unread: Int?
    }

    /// One compact status-bar string: colored dots with counts only. Zero counts and
    /// providers that are not running are omitted; an unknown running count shows as a gray "?".
    static func compactTitle(codex: Counts?, claude: Counts?) -> NSAttributedString {
        let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let tag: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let result = NSMutableAttributedString()
        func dot(_ indicator: StatusIndicator, _ count: Int?, _ label: String) {
            result.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: indicator.color(for: count), .baselineOffset: 1
            ]))
            result.append(NSAttributedString(string: label + " ", attributes: text))
        }
        for (name, counts) in [("Cx", codex), ("Cl", claude)] {
            guard let counts else { continue }
            var entries: [(StatusIndicator, Int?, String)] = []
            if counts.running == nil { entries.append((.running, nil, "?")) }
            else if let n = counts.running, n > 0 { entries.append((.running, n, countLabel(n))) }
            if counts.waiting > 0 { entries.append((.waiting, counts.waiting, countLabel(counts.waiting))) }
            if let n = counts.unread, n > 0 { entries.append((.unread, n, countLabel(n))) }
            guard !entries.isEmpty else { continue }
            result.append(NSAttributedString(string: " \(name) ", attributes: tag))
            for entry in entries { dot(entry.0, entry.1, entry.2) }
        }
        if result.length > 0 {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    static func accessibilityValue(running: Int?, unread: Int?, waiting: Int? = nil,
                                   provider: String = "Codex") -> String {
        let wait = (waiting ?? 0) > 0 ? "；等待输入 \(countLabel(waiting))" : ""
        return "\(provider) 运行 \(countLabel(running))\(wait)；已完成未读 \(countLabel(unread))"
    }
}
