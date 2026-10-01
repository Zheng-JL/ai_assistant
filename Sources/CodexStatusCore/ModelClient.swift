import Foundation

public enum APIFormat: String, Codable, Sendable, CaseIterable {
    case openAI
    case anthropic

    public var label: String { self == .openAI ? "OpenAI 兼容" : "Anthropic" }
}

public struct ModelConfig: Sendable, Equatable {
    public var format: APIFormat
    public var endpoint: String
    public var model: String
    public var apiKey: String

    public init(format: APIFormat, endpoint: String, model: String, apiKey: String) {
        self.format = format; self.endpoint = endpoint; self.model = model; self.apiKey = apiKey
    }
}

public enum ModelError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case insecureEndpoint
    case missingField(String)
    case http(Int, String)
    case emptyReply
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "请求地址无法识别"
        case .insecureEndpoint: return "请求地址必须是 https（本机地址除外）"
        case .missingField(let name): return "还没有填写\(name)"
        case .http(let code, let detail): return "接口返回 \(code)：\(detail)"
        case .emptyReply: return "模型没有返回内容"
        case .transport(let detail): return "网络请求失败：\(detail)"
        }
    }
}

/// Calls a chat model over HTTP. The endpoint, model name and key are entirely the user's own.
public struct ModelClient: Sendable {
    private let session: URLSession
    public static let timeout: TimeInterval = 240

    public init(session: URLSession = .shared) { self.session = session }

    /// Normalises what the user typed into the real request URL, and refuses plain http for remote hosts.
    public static func requestURL(for config: ModelConfig) throws -> URL {
        let trimmed = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, scheme == "https" || scheme == "http" else {
            throw ModelError.invalidEndpoint
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        if scheme == "http" && !local { throw ModelError.insecureEndpoint }
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let tail = config.format == .openAI ? "/chat/completions" : "/messages"
        if !path.hasSuffix(tail) {
            if path.isEmpty { path = "/v1" }
            path += tail
        }
        components.path = path
        guard let url = components.url else { throw ModelError.invalidEndpoint }
        return url
    }

    public func complete(config: ModelConfig, system: String, user: String, maxTokens: Int = 4096) async throws -> String {
        guard !config.endpoint.trimmingCharacters(in: .whitespaces).isEmpty else { throw ModelError.missingField("请求地址") }
        guard !config.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw ModelError.missingField("模型名称") }
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw ModelError.missingField("API Key") }
        var request = URLRequest(url: try Self.requestURL(for: config), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch config.format {
        case .openAI:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": config.model, "stream": false, "temperature": 0.2,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": config.model, "max_tokens": maxTokens, "system": system, "temperature": 0.2,
                    "messages": [["role": "user", "content": user]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ModelError.transport(Self.scrub((error as NSError).localizedDescription, key: config.apiKey)) }
        guard let http = response as? HTTPURLResponse else { throw ModelError.emptyReply }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw ModelError.http(http.statusCode, Self.scrub(detail, key: config.apiKey))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelError.emptyReply }
        let text: String?
        switch config.format {
        case .openAI:
            let choice = (object["choices"] as? [[String: Any]])?.first
            text = (choice?["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            text = (object["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.emptyReply }
        return text
    }

    /// Never let the key travel into an error message that ends up on screen.
    static func scrub(_ text: String, key: String) -> String {
        key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[已隐藏]")
    }
}
