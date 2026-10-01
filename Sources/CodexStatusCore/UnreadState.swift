import CryptoKit
import Foundation

public struct UnreadState: Sendable {
    public let threadIDs: Set<String>
    public let identityKey: String?

    public static let standardLocalHostKey: String = {
        let digest = SHA256.hash(data: Data(#"["local","local",null]"#.utf8))
        return "local:" + digest.map { String(format: "%02x", $0) }.joined()
    }()

    public static func decode(_ data: Data) throws -> Self {
        let state: Root
        do { state = try JSONDecoder().decode(Root.self, from: data) }
        catch { throw SourceError.malformed }
        guard let current = state.readState, current.version == 1 else {
            throw SourceError.unsupported("Codex 未读状态版本不受支持")
        }
        // Never merge identities, legacy state, or local WebSocket storage.
        guard current.unreadByIdentity.count == 1,
              let identity = current.unreadByIdentity.first else {
            throw SourceError.unsupported("缺少唯一阅读配置，无法确认当前未读来源")
        }
        let localKeys = identity.value.keys.filter { $0.hasPrefix("local:") }
        guard localKeys.allSatisfy({ $0 == standardLocalHostKey }) else {
            throw SourceError.unsupported("当前本地连接的阅读配置不受支持")
        }
        guard let ids = identity.value[standardLocalHostKey] else {
            throw SourceError.unsupported("缺少本机阅读配置，无法确认未读状态")
        }
        guard ids.allSatisfy({ normalizedID($0) != nil }) else { throw SourceError.malformed }
        return Self(threadIDs: Set(ids.compactMap(normalizedID)), identityKey: identity.key)
    }

    private struct Root: Decodable {
        let readState: StoredState?
        enum CodingKeys: String, CodingKey {
            case readState = "electron-thread-read-state-v1"
        }
    }
    private struct StoredState: Decodable {
        let version: Int
        let unreadByIdentity: [String: [String: [String]]]
    }
}
