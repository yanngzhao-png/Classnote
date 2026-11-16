import Foundation
import Security
import ClassnoteCore

struct AppSettings: Codable {
    var realtimeModel = TranscriptionOptions.accurateModel
    var fileModel = "gpt-transcribe"
    var textModel = "gpt-5.6-terra"
    var vocabulary = ""
    var fontSize: Double = 23
    var captionWidth: Double = 560
    var captionHeight: Double = 300
    var bilingual = true
    var noiseThreshold: Double = 0.008
    // Optional so decoding the existing settings preserves all configured model names.
    var tuition: TuitionConfiguration?
    var notion: NotionConfiguration?
    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: "settings.v1"), let s = try? JSONDecoder().decode(Self.self, from: d) else { return .init() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings.v1") } }
}
enum Keychain {
    private static func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.classnote.mac", kSecAttrAccount as String: account] }
    static func read() throws -> String { try readAccount("openai-api-key") }
    static func readNotion() throws -> String { try readAccount("notion-api-token") }
    static func save(_ key: String) throws { try saveAccount(key, account: "openai-api-key") }
    static func saveNotion(_ key: String) throws { try saveAccount(key, account: "notion-api-token") }
    static func removeNotion() throws {
        let status = SecItemDelete(query("notion-api-token") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("移除 Notion 凭证失败（\(status)）。") }
    }
    private static func readAccount(_ account: String) throws -> String {
        let query = query(account)
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AppFailure("无法读取钥匙串（\(status)）。") }
        return value
    }
    private static func saveAccount(_ key: String, account: String) throws {
        let query = query(account)
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(q as CFDictionary, nil)
            guard result == errSecSuccess else { throw AppFailure("保存钥匙串失败（\(result)）。") }
        } else if status != errSecSuccess { throw AppFailure("更新钥匙串失败（\(status)）。") }
    }
}
