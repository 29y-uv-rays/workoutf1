import Foundation
import Security

final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let service = "com.example.APEX.gemini"
    private let keyAccount = "api-key"
    private let modelAccount = "model-id"

    private init() {}

    var geminiKey: String? { retrieve(account: keyAccount) }
    var hasGeminiKey: Bool { geminiKey != nil && !geminiKey!.isEmpty }

    func setGeminiKey(_ key: String) { set(key, account: keyAccount) }
    func deleteGeminiKey() { delete(account: keyAccount) }

    var geminiModelID: String? { retrieve(account: modelAccount) }
    func setGeminiModelID(_ id: String) { set(id, account: modelAccount) }
    func deleteGeminiModelID() { delete(account: modelAccount) }
    func deleteAllKeys() { deleteGeminiKey(); deleteGeminiModelID() }

    private func retrieve(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func set(_ value: String, account: String) {
        let data = value.data(using: .utf8)!
        delete(account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: data]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
