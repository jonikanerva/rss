import Foundation
import Security

/// Errors raised by KeychainHelper when the underlying Security APIs fail.
/// `encodingFailed` covers UTF-8 conversion; `osStatus` wraps a `SecItem…` return code.
nonisolated enum KeychainError: Error, Sendable {
  case encodingFailed
  case osStatus(OSStatus)
}

/// Simple Keychain wrapper for storing Feedbin credentials and cloud API keys.
/// All methods are nonisolated since Keychain APIs are thread-safe. `save`/`delete`
/// throw typed errors so callers can distinguish real failures from the not-found
/// case (which is treated as success for deletes).
nonisolated enum KeychainHelper {
  private static let service = "com.feeder.app"

  // MARK: - Account keys

  /// Keychain account key under which the Feedbin password is stored.
  static let feedbinPasswordKey = "feedbin_password"
  /// Keychain account key under which the OpenAI API key value is stored.
  /// Named `…KeychainKey` (not `APIKey`) so call sites read unambiguously as
  /// "the keychain key" rather than "the API key value".
  static let openAIAPIKeychainKey = "openai_api_key"
  static let vercelAPIKeychainKey = "vercel_ai_gateway_api_key"

  static func save(key: String, value: String) throws(KeychainError) {
    guard let data = value.data(using: .utf8) else {
      throw .encodingFailed
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw .osStatus(status) }
    var item = query
    item[kSecValueData as String] = data
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    if addStatus != errSecSuccess { throw .osStatus(addStatus) }
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
