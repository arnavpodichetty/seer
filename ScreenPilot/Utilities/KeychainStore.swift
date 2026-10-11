import Foundation
import Security

/// Stores secrets (the Gemini and Groq API keys) in the login Keychain rather than in
/// UserDefaults or source code.
nonisolated enum KeychainStore {
    static let geminiService = "ScreenPilot.GeminiAPIKey"
    static let groqService = "ScreenPilot.GroqAPIKey"
    static let customService = "ScreenPilot.CustomAPIKey"
    static let account = "default"

    static func read(service: String = geminiService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves `value`, or deletes the item when it is empty. Returns false on failure.
    @discardableResult
    static func write(_ value: String, service: String = geminiService) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var attributes = base
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrLabel as String] = "ScreenPilot API key (\(service))"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
