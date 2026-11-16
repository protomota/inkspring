import Foundation
import Security

enum ProviderKey: String, CaseIterable, Identifiable {
    case anthropic, openai, gemini, apify, x

    var id: Self { self }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .apify: "Apify"
        case .x: "X Bearer Token"
        }
    }

    var managementURL: URL {
        let address = switch self {
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .openai: "https://platform.openai.com/api-keys"
        case .gemini: "https://aistudio.google.com/api-keys"
        case .apify: "https://console.apify.com/settings/integrations"
        case .x: "https://console.x.com/"
        }
        return URL(string: address)!
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.protomota.inkspring.native.providers",
            kSecAttrAccount as String: rawValue
        ]
    }

    var isSaved: Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw WorkspaceError("Add your \(name) key in Settings.") }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw WorkspaceError("Could not read the \(name) key.")
        }
        return value
    }

    func save(_ value: String, replaceExisting: Bool = true) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count < 8192,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceError("Enter a valid \(name) key.")
        }
        let data = Data(key.utf8)
        let status = replaceExisting
            ? SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            : errSecItemNotFound
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            let added = SecItemAdd(attributes as CFDictionary, nil)
            if !replaceExisting, added == errSecDuplicateItem {
                throw WorkspaceError("A \(name) key is already saved. Request a replacement to change it.")
            }
            try check(added)
        } else {
            try check(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw WorkspaceError("Keychain couldn’t update \(name) (\(status)).")
        }
    }
}

struct ProviderCatalog: Decodable {
    struct Model: Decodable, Identifiable {
        let id: String
        let name: String
    }

    let defaults: [String: String]
    let anthropic: [Model]
    let openai: [Model]
    let gemini: [Model]
    let openaiImage: [Model]
    let geminiImage: [Model]

    static var bundled: Self? {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
