import Foundation

/// Best-effort removal of secrets from text before it leaves the machine.
/// It catches common key formats and `name = value` style assignments; it is not a guarantee.
public struct Redactor: Sendable {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }
    private let rules: [Rule]

    public init() {
        let table: [(String, String)] = [
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "[已隐藏私钥]"),
            (#"\b(?:sk|rk)-[A-Za-z0-9_\-]{16,}"#, "[已隐藏密钥]"),
            (#"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#, "[已隐藏密钥]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[已隐藏密钥]"),
            (#"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#, "[已隐藏令牌]"),
            (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "[已隐藏令牌]"),
            (#"\bBearer\s+[A-Za-z0-9._~+/=\-]{16,}"#, "Bearer [已隐藏]"),
            (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, "[已隐藏令牌]"),
            (#"(://)[^/\s:@]+:[^/\s@]+@"#, "$1[已隐藏]@"),
            (#"(?i)\b([A-Za-z0-9_\-]*(?:api[_-]?key|secret|token|passwd|password|authorization|private[_-]?key|access[_-]?key)\s*["']?\s*[:=]\s*["']?)([^\s"',;)}\]]{6,})"#, "$1[已隐藏]")
        ]
        rules = table.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(regex: $0, template: template) }
        }
    }

    public func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            let matches = rule.regex.numberOfMatches(in: result, range: range)
            guard matches > 0 else { continue }
            count += matches
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return (result, count)
    }
}
