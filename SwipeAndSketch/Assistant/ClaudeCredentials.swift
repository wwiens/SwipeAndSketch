import Foundation
import Security

/// A user-supplied API key for one provider (Claude, OpenAI, or Gemini), in this device's Keychain.
/// Never persisted in defaults, project files, or transcripts.
struct APICredentials {
    static let shared = APICredentials(service: "noventix.SwipeAndSketch.claude")
    static let openAI = APICredentials(service: "noventix.SwipeAndSketch.openai", provider: .openAI)
    static let gemini = APICredentials(service: "noventix.SwipeAndSketch.gemini", provider: .gemini)
    static let didChange = Notification.Name("SwipeAndSketch.claudeCredentialsDidChange")
    var service: String
    var provider: AIProvider = .claude

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AssistantFailure(message: "The \(provider.title) API key could not be read from Keychain. Unlock this device and try again.")
        }
        return key
    }

    func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace),
              key.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else {
            throw AssistantFailure(message: "Enter a \(provider.title) API key without spaces.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantFailure(message: "The \(provider.title) API key could not be saved to Keychain.") }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantFailure(message: "The \(provider.title) API key could not be removed from Keychain.")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// The Claude key's store, by its first name.
typealias ClaudeCredentials = APICredentials
