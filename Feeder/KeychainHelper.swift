import Foundation
import OSLog
import Security

/// `osStatus` wraps a `SecItem…` return code. `encodingFailed` covers item
/// data that does not convert to or from the format that its store writes,
/// such as data that is missing or not valid UTF-8, or JSON that does not decode.
nonisolated enum KeychainError: Error, Equatable, Sendable {
  case encodingFailed
  case osStatus(OSStatus)
}

/// Every call can wait for the Keychain access dialog: never call it on the
/// main actor. `delete` treats a missing item as success.
nonisolated enum KeychainHelper {
  private static let service = "com.feeder.app"
  private static let logger = Logger(subsystem: "com.feeder.app", category: "Keychain")

  // MARK: - Account keys

  /// Keychain account key of the item that holds the Feedbin username and password.
  static let feedbinAccountKey = "feedbin_account"
  /// Keychain account key of the Feedbin password item that an older build wrote.
  static let feedbinPasswordKey = "feedbin_password"
  /// Keychain account key under which the OpenAI API key value is stored.
  /// Named `…KeychainKey` (not `APIKey`) so call sites read unambiguously as
  /// "the keychain key" rather than "the API key value".
  static let openAIAPIKeychainKey = "openai_api_key"
  static let vercelAPIKeychainKey = "vercel_ai_gateway_api_key"

  // MARK: - Writes

  /// Fails with `errSecDuplicateItem` when the item exists. A new item gets a
  /// default access list that trusts the current build.
  static func add(key: String, value: String) throws(KeychainError) {
    var item = baseQuery(key)
    item[kSecValueData as String] = Data(value.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status != errSecSuccess else { return }
    logFailure("add", key: key, error: .osStatus(status))
    throw .osStatus(status)
  }

  static func delete(key: String) throws(KeychainError) {
    let status = SecItemDelete(baseQuery(key) as CFDictionary)
    guard status != errSecSuccess, status != errSecItemNotFound else { return }
    logFailure("delete", key: key, error: .osStatus(status))
    throw .osStatus(status)
  }

  // MARK: - Reads

  /// Nil means that no item exists. A throw is a failed read, never a missing key.
  static func read(key: String) throws(KeychainError) -> String? {
    let (status, result) = copyMatching(key: key, returning: kSecReturnData)
    do throws(KeychainError) {
      return try decodeReadResult(status: status, data: result as? Data)
    } catch {
      logFailure("read", key: key, error: error)
      throw error
    }
  }

  /// Must request attributes only: a request for the secret data can show the
  /// Keychain access dialog.
  static func exists(key: String) throws(KeychainError) -> Bool {
    let (status, _) = copyMatching(key: key, returning: kSecReturnAttributes)
    do throws(KeychainError) {
      return try decodeExistsResult(status: status)
    } catch {
      logFailure("probe", key: key, error: error)
      throw error
    }
  }

  /// Empty data stays an empty string, never nil: nil means that no item
  /// exists, and each caller decides what an empty value means.
  static func decodeReadResult(status: OSStatus, data: Data?) throws(KeychainError) -> String? {
    switch status {
    case errSecSuccess:
      guard let data, let value = String(data: data, encoding: .utf8) else { throw .encodingFailed }
      return value
    case errSecItemNotFound:
      return nil
    default:
      throw .osStatus(status)
    }
  }

  static func decodeExistsResult(status: OSStatus) throws(KeychainError) -> Bool {
    switch status {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return false
    default:
      throw .osStatus(status)
    }
  }

  // MARK: - Private

  private static func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  private static func copyMatching(key: String, returning returnKey: CFString) -> (OSStatus, AnyObject?) {
    var query = baseQuery(key)
    query[returnKey as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result)
  }

  /// `key` must be an account constant, never key material: the line logs it with
  /// public privacy.
  private static func logFailure(_ operation: String, key: String, error: KeychainError) {
    if error == .osStatus(errSecInvalidOwnerEdit) {
      logger.error(
        "Keychain \(operation, privacy: .public) of \(key, privacy: .public) failed with errSecInvalidOwnerEdit (-25244): invalid attempt to change the owner of this item"
      )
    } else {
      logger.error(
        "Keychain \(operation, privacy: .public) of \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
  }
}
