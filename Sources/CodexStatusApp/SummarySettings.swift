import CodexStatusCore
import Foundation
import Security

/// Non-secret settings for the AI summary. The API key lives only in the Keychain.
struct SummarySettings {
    private static let formatKey = "summaryAPIFormat"
    private static let endpointKey = "summaryEndpoint"
    private static let modelKey = "summaryModel"
    private static let confirmedHostKey = "summaryConfirmedHost"
    private static let maxCharsKey = "summaryMaxChars"

    var format: APIFormat
    var endpoint: String
    var model: String
    var confirmedHost: String?
    var maxChars: Int

    static func load(_ defaults: UserDefaults = .standard) -> SummarySettings {
        SummarySettings(
            format: APIFormat(rawValue: defaults.string(forKey: formatKey) ?? "") ?? .openAI,
            endpoint: defaults.string(forKey: endpointKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            confirmedHost: defaults.string(forKey: confirmedHostKey),
            maxChars: defaults.object(forKey: maxCharsKey) as? Int ?? 60_000)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(format.rawValue, forKey: Self.formatKey)
        defaults.set(endpoint, forKey: Self.endpointKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(maxChars, forKey: Self.maxCharsKey)
        if let confirmedHost { defaults.set(confirmedHost, forKey: Self.confirmedHostKey) }
        else { defaults.removeObject(forKey: Self.confirmedHostKey) }
    }

    var isComplete: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Host that would receive the conversation text, for the confirmation prompt.
    var host: String? {
        (try? ModelClient.requestURL(for: ModelConfig(format: format, endpoint: endpoint, model: model, apiKey: "-")))?.host
    }
}

/// Stores the API key in the macOS Keychain, never in preferences or files.
enum KeychainStore {
    static let defaultService = "com.zhengjl.codexstatus.llm"
    private static let account = "api-key"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(service: String = defaultService) -> String? {
        var request = query(service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an entry exists, without reading the secret (so no keychain prompt can appear).
    static func exists(service: String = defaultService) -> Bool {
        var request = query(service)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func write(_ value: String, service: String = defaultService) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query(service)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String = defaultService) -> Bool {
        let status = SecItemDelete(query(service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
