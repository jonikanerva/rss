import Foundation
import Security

/// The property names are the JSON keys of the stored Keychain item: a rename
/// makes every stored account unreadable.
nonisolated struct FeedbinCredentials: Sendable, Equatable, Codable {
  let username: String
  let password: String

  /// False when either value is empty: such a pair is no account.
  var isComplete: Bool { !username.isEmpty && !password.isEmpty }
}

nonisolated protocol FeedbinCredentialStore: Sendable {
  /// Nil means that no account is stored. A throw is a failed read, never a
  /// missing account.
  func load() async throws(KeychainError) -> FeedbinCredentials?
  /// Must not stop for cancellation: a save calls it after its remove completes.
  func add(_ credentials: FeedbinCredentials) async throws(KeychainError)
  /// Removing a missing account succeeds.
  func remove() async throws(KeychainError)
  /// Reads the storage that an older build wrote. Nil and a throw mean what
  /// they mean for `load()`.
  func loadLegacy() async throws(KeychainError) -> FeedbinCredentials?
  /// Afterwards `loadLegacy()` returns nil, even when a Keychain delete fails.
  func removeLegacy() async
}

actor KeychainFeedbinCredentialStore {
  private static let legacyUsernameDefaultsKey = "feedbin_username"

  func load() throws(KeychainError) -> FeedbinCredentials? {
    guard let item = try KeychainHelper.read(key: KeychainHelper.feedbinAccountKey) else { return nil }
    return try Self.decodeItem(item)
  }

  /// The username stays in the item data, never in an attribute (`STACK.md § 8`).
  func add(_ credentials: FeedbinCredentials) throws(KeychainError) {
    try KeychainHelper.add(key: KeychainHelper.feedbinAccountKey, value: Self.encodeItem(credentials))
  }

  func remove() throws(KeychainError) {
    try KeychainHelper.delete(key: KeychainHelper.feedbinAccountKey)
  }

  func loadLegacy() throws(KeychainError) -> FeedbinCredentials? {
    try Self.legacyCredentials(username: UserDefaults.standard.string(forKey: Self.legacyUsernameDefaultsKey)) {
      () throws(KeychainError) -> String? in
      try KeychainHelper.read(key: KeychainHelper.feedbinPasswordKey)
    }
  }

  func removeLegacy() {
    UserDefaults.standard.removeObject(forKey: Self.legacyUsernameDefaultsKey)
    try? KeychainHelper.delete(key: KeychainHelper.feedbinPasswordKey)
  }

  // MARK: - Pure rules

  nonisolated static func encodeItem(_ credentials: FeedbinCredentials) throws(KeychainError) -> String {
    do {
      return try String(decoding: JSONEncoder().encode(credentials), as: UTF8.self)
    } catch {
      throw .encodingFailed
    }
  }

  /// Data that does not decode, including empty data, is a failed read, never
  /// a missing account.
  nonisolated static func decodeItem(_ item: String) throws(KeychainError) -> FeedbinCredentials {
    do {
      return try JSONDecoder().decode(FeedbinCredentials.self, from: Data(item.utf8))
    } catch {
      throw .encodingFailed
    }
  }

  /// Reads the password only for a non-empty username: without a username
  /// there is no account, and the read could show the Keychain access dialog.
  nonisolated static func legacyCredentials(
    username: String?,
    readPassword: () throws(KeychainError) -> String?
  ) throws(KeychainError) -> FeedbinCredentials? {
    guard let username, !username.isEmpty, let password = try readPassword() else { return nil }
    return FeedbinCredentials(username: username, password: password)
  }
}

extension KeychainFeedbinCredentialStore: FeedbinCredentialStore {}

actor MemoryFeedbinCredentialStore {
  private var credentials: FeedbinCredentials?
  private var legacyUsername: String?
  private var legacyPassword: String?
  private var loadFailure: KeychainError?
  private var legacyPasswordReadFailure: KeychainError?

  init(credentials: FeedbinCredentials? = nil, legacyUsername: String? = nil, legacyPassword: String? = nil) {
    self.credentials = credentials
    self.legacyUsername = legacyUsername
    self.legacyPassword = legacyPassword
  }

  func configureLoadFailure(_ failure: KeychainError?) { loadFailure = failure }

  func configureLegacyPasswordReadFailure(_ failure: KeychainError?) { legacyPasswordReadFailure = failure }

  func load() throws(KeychainError) -> FeedbinCredentials? {
    if let loadFailure { throw loadFailure }
    return credentials
  }

  func add(_ credentials: FeedbinCredentials) throws(KeychainError) {
    guard self.credentials == nil else { throw .osStatus(errSecDuplicateItem) }
    self.credentials = credentials
  }

  func remove() throws(KeychainError) {
    credentials = nil
  }

  func loadLegacy() throws(KeychainError) -> FeedbinCredentials? {
    try KeychainFeedbinCredentialStore.legacyCredentials(username: legacyUsername) {
      () throws(KeychainError) -> String? in
      if let legacyPasswordReadFailure { throw legacyPasswordReadFailure }
      return legacyPassword
    }
  }

  func removeLegacy() {
    legacyUsername = nil
    legacyPassword = nil
  }
}

extension MemoryFeedbinCredentialStore: FeedbinCredentialStore {}
