import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.echo.transcribe"
    private static let account = "AzureSpeechAPIKey"

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let attrs = query.merging([kSecValueData as String: data]) { $1 }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Keychain save failed (OSStatus \(s))."
        }
    }
}

/// Non-secret Azure configuration. The key itself lives in the Keychain; the
/// resource name is just an identifier that forms the endpoint host, so
/// UserDefaults is the right home for it.
enum AzureSettings {
    private static let resourceNameKey = "azureResourceName"

    static var resourceName: String {
        get { UserDefaults.standard.string(forKey: resourceNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: resourceNameKey) }
    }
}
