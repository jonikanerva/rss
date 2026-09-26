import Foundation
import Security

nonisolated struct FeedbinCredentials: Sendable, Equatable {
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
}

actor KeychainFeedbinCredentialStore {
  private static let usernameDefaultsKey = "feedbin_username"

  func load() throws(KeychainError) -> FeedbinCredentials? {
    try Self.credentials(username: UserDefaults.standard.string(forKey: Self.usernameDefaultsKey)) {
      () throws(KeychainError) -> String? in
      try KeychainHelper.read(key: KeychainHelper.feedbinPasswordKey)
    }
  }

  func add(_ credentials: FeedbinCredentials) throws(KeychainError) {
    try KeychainHelper.add(key: KeychainHelper.feedbinPasswordKey, value: credentials.password)
    UserDefaults.standard.set(credentials.username, forKey: Self.usernameDefaultsKey)
  }

  func remove() throws(KeychainError) {
    try KeychainHelper.delete(key: KeychainHelper.feedbinPasswordKey)
    UserDefaults.standard.removeObject(forKey: Self.usernameDefaultsKey)
  }

  /// Reads the password only for a non-empty username: without a username
  /// there is no account, and the read could show the Keychain access dialog.
  nonisolated static func credentials(
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
  private var loadFailure: KeychainError?
  private var addFailure: KeychainError?
  private var removeFailure: KeychainError?

  init(credentials: FeedbinCredentials? = nil) { self.credentials = credentials }

  func configureLoadFailure(_ failure: KeychainError?) { loadFailure = failure }
  func configureAddFailure(_ failure: KeychainError?) { addFailure = failure }
  func configureRemoveFailure(_ failure: KeychainError?) { removeFailure = failure }

  func load() throws(KeychainError) -> FeedbinCredentials? {
    if let loadFailure { throw loadFailure }
    return credentials
  }

  func add(_ credentials: FeedbinCredentials) throws(KeychainError) {
    if let addFailure { throw addFailure }
    guard self.credentials == nil else { throw .osStatus(errSecDuplicateItem) }
    self.credentials = credentials
  }

  func remove() throws(KeychainError) {
    if let removeFailure { throw removeFailure }
    credentials = nil
  }
}

extension MemoryFeedbinCredentialStore: FeedbinCredentialStore {}
