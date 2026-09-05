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
    private static let vocabularyKey = "customVocabulary"
    private static let cleanTranscriptKey = "cleanTranscript"

    static var resourceName: String {
        get { UserDefaults.standard.string(forKey: resourceNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: resourceNameKey) }
    }

    /// Names, jargon and proper nouns to bias recognition toward. Stored as free
    /// text so the settings field stays a simple editor; one term per line.
    static var vocabularyText: String {
        get { UserDefaults.standard.string(forKey: vocabularyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: vocabularyKey) }
    }

    static var vocabularyPhrases: [String] {
        vocabularyText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// When true, the server strips fillers and false starts.
    static var cleanTranscript: Bool {
        get { UserDefaults.standard.bool(forKey: cleanTranscriptKey) }
        set { UserDefaults.standard.set(newValue, forKey: cleanTranscriptKey) }
    }
}

/// What goes into an exported document.
enum ExportSettings {
    private static let timestampsKey = "exportIncludeTimestamps"
    private static let speakersKey = "exportIncludeSpeakers"

    static var includeTimestamps: Bool {
        get { UserDefaults.standard.object(forKey: timestampsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: timestampsKey) }
    }

    static var includeSpeakerLabels: Bool {
        get { UserDefaults.standard.object(forKey: speakersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: speakersKey) }
    }
}

/// Replacements applied automatically to every new transcript, so a name the
/// model always gets wrong only has to be fixed once.
enum CorrectionSettings {
    private static let rulesKey = "correctionRules"

    /// One rule per line, written as `wrong => right`.
    static var rulesText: String {
        get { UserDefaults.standard.string(forKey: rulesKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: rulesKey) }
    }

    static var rules: [(wrong: String, right: String)] {
        rulesText.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let wrong = parts[0].trimmingCharacters(in: .whitespaces)
            let right = parts[1].trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty else { return nil }
            return (wrong, right)
        }
    }

    static func apply(to text: String) -> String {
        rules.reduce(text) { result, rule in
            result.replacingOccurrences(of: rule.wrong,
                                        with: rule.right,
                                        options: [.caseInsensitive])
        }
    }
}
