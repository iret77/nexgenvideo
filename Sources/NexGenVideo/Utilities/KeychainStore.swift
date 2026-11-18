import Foundation
import Security

enum KeychainStore {
    private static let service: String = Bundle.main.bundleIdentifier ?? "de.h5ventures.nexgenvideo"

    private static func matchingQuery(account: String, keychain: SecKeychain?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    @discardableResult
    static func save(_ value: String, account: String, keychain: SecKeychain? = nil) -> Bool {
        let data = Data(value.utf8)
        let query = matchingQuery(account: account, keychain: keychain)
        var attrs: [String: Any] = [kSecValueData as String: data]
        if keychain == nil { attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            if let keychain {
                insert.removeValue(forKey: kSecMatchSearchList as String)
                insert[kSecUseKeychain as String] = keychain
            }
            insert.merge(attrs) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func load(account: String, keychain: SecKeychain? = nil) -> String? {
        var query = matchingQuery(account: account, keychain: keychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func delete(account: String, keychain: SecKeychain? = nil) -> Bool {
        let query = matchingQuery(account: account, keychain: keychain)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum HangDiagnosticReplayKeychain {
    static func saveAndVerify(_ value: String, recording: String) throws {
        let keychain = try isolatedCIKeychain()
        let account = "hang-diagnostic-\(recording)"
        guard KeychainStore.save(value, account: account, keychain: keychain) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard KeychainStore.load(account: account, keychain: keychain) == value else {
            KeychainStore.delete(account: account, keychain: keychain)
            throw CocoaError(.fileReadNoPermission)
        }
    }

    static func load(recording: String) -> String? {
        do {
            return KeychainStore.load(account: "hang-diagnostic-\(recording)", keychain: try isolatedCIKeychain())
        } catch { return nil }
    }

    static func delete(recording: String) {
        do {
            KeychainStore.delete(account: "hang-diagnostic-\(recording)", keychain: try isolatedCIKeychain())
        } catch {}
    }

    private static func isolatedCIKeychain() throws -> SecKeychain? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              let path = environment["NGV_HANG_TEST_KEYCHAIN"] else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = file.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        guard file.lastPathComponent == "replay.keychain-db",
              directory.lastPathComponent.hasPrefix("ngv-hang-keychain-"),
              directory.deletingLastPathComponent().path == home.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        var keychain: SecKeychain?
        guard file.path.withCString({ SecKeychainOpen($0, &keychain) }) == errSecSuccess,
              let keychain else { throw CocoaError(.fileReadNoPermission) }
        return keychain
    }
}
