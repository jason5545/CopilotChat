import Foundation
import CryptoKit

/// Encrypts/decrypts sensitive data using a device-specific key stored in the Keychain.
/// Encrypted blobs are safe to sync via iCloud since decryption requires the
/// device-local key (stored in Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly).
enum SecureStorage {
    private static let keychainService = "com.copilotchat.securestorage"
    private static let encryptionKeyTag = "com.copilotchat.encryption-key"

    // MARK: - Encrypt / Decrypt

    /// Encrypt a string and return a base64-encoded ciphertext.
    /// The encryption key is lazily created in the Keychain on first use.
    static func encrypt(_ plaintext: String) -> Data? {
        guard !plaintext.isEmpty, let key = getOrCreateKey() else { return nil }
        let box = SealedBox(key: key, plaintext: plaintext)
        return box.encoded
    }

    /// Decrypt a base64-encoded ciphertext back to the original string.
    static func decrypt(_ ciphertext: Data) -> String? {
        guard let key = getOrCreateKey() else { return nil }
        guard let box = SealedBox(key: key, encoded: ciphertext) else { return nil }
        return box.plaintext
    }

    /// Encrypt a dictionary to a base64 Data blob.
    static func encryptDictionary(_ dict: [String: String]) -> Data? {
        guard let jsonData = try? JSONEncoder().encode(dict) else { return nil }
        guard !dict.isEmpty else { return nil }
        return encryptJSONData(jsonData)
    }

    /// Decrypt a base64 Data blob back to a dictionary.
    static func decryptDictionary(_ data: Data) -> [String: String]? {
        guard let jsonData = decryptJSONData(data) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: jsonData)
    }

    // MARK: - Internal helpers

    private static func encryptJSONData(_ data: Data) -> Data? {
        guard let key = getOrCreateKey() else { return nil }
        let sealed = try? AES.GCM.seal(data, using: key)
        return sealed?.combined
    }

    private static func decryptJSONData(_ combined: Data) -> Data? {
        guard let key = getOrCreateKey() else { return nil }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        return try? AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Key Management

    private static func getOrCreateKey() -> SymmetricKey? {
        if let existing = loadKey() { return existing }
        let newKey = SymmetricKey(size: .bits256)
        if saveKey(newKey) { return newKey }
        return nil
    }

    private static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: encryptionKeyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func saveKey(_ key: SymmetricKey) -> Bool {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: encryptionKeyTag,
        ]
        SecItemDelete(query as CFDictionary)
        var newItem = query
        newItem[kSecValueData as String] = keyData
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - SealedBox helpers

    private struct SealedBox {
        let plaintext: String
        let encoded: Data

        init(key: SymmetricKey, plaintext: String) {
            self.plaintext = plaintext
            guard let data = plaintext.data(using: .utf8),
                  let sealed = try? AES.GCM.seal(data, using: key) else {
                self.encoded = Data()
                return
            }
            self.encoded = sealed.combined ?? Data()
        }

        init?(key: SymmetricKey, encoded: Data) {
            guard let sealedBox = try? AES.GCM.SealedBox(combined: encoded),
                  let decrypted = try? AES.GCM.open(sealedBox, using: key),
                  let text = String(data: decrypted, encoding: .utf8) else {
                return nil
            }
            self.plaintext = text
            self.encoded = encoded
        }
    }
}