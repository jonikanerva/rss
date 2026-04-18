import Foundation
import OSLog
import Security

/// Errors raised by KeychainHelper when the underlying Security APIs fail.
/// `encodingFailed` covers UTF-8 conversion; `osStatus` wraps a `SecItem…` return code.
nonisolated enum KeychainError: Error, Sendable {
  case encodingFailed
  case osStatus(OSStatus)
}

nonisolated private let keychainLogger = Logger(subsystem: "com.feeder.app", category: "Keychain")

/// Simple Keychain wrapper for storing Feedbin credentials and the OpenAI API key.
/// All methods are nonisolated since Keychain APIs are thread-safe. `save`/`delete`
/// throw typed errors so callers can distinguish real failures from the not-found
/// case (which is treated as success for deletes).
nonisolated enum KeychainHelper {
  private static let service = "com.feeder.app"

  static func save(key: String, value: String) throws(KeychainError) {
    guard let data = value.data(using: .utf8) else {
      throw .encodingFailed
    }

    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
    if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
      keychainLogger.error("Keychain delete-before-save failed: \(deleteStatus)")
    }

    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      throw .osStatus(addStatus)
    }
  }

  static func load(key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  static func delete(key: String) throws(KeychainError) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      throw .osStatus(status)
    }
  }
}
