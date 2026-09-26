import Foundation
import Security

nonisolated protocol ClassificationKeyStore: Sendable {
  /// Follows the contract of `KeychainHelper.read(key:)`.
  func load(provider: ClassificationProviderKind) async throws(KeychainError) -> String?
  /// Follows the contract of `KeychainHelper.exists(key:)`.
  func exists(provider: ClassificationProviderKind) async throws(KeychainError) -> Bool
  /// Must not stop for cancellation: a save calls it after its delete completes.
  func add(_ value: String, provider: ClassificationProviderKind) async throws
  func remove(provider: ClassificationProviderKind) async throws
}

actor KeychainClassificationKeyStore {
  func load(provider: ClassificationProviderKind) throws(KeychainError) -> String? {
    guard !Task.isCancelled, let key = provider.keychainKey else { return nil }
    return try KeychainHelper.read(key: key)
  }

  func exists(provider: ClassificationProviderKind) throws(KeychainError) -> Bool {
    guard !Task.isCancelled, let key = provider.keychainKey else { return false }
    return try KeychainHelper.exists(key: key)
  }

  func add(_ value: String, provider: ClassificationProviderKind) throws {
    guard let key = provider.keychainKey else { return }
    // Security calls block and cannot be cancelled after entry; keep them on this actor.
    try KeychainHelper.add(key: key, value: value)
  }

  func remove(provider: ClassificationProviderKind) throws {
    try Task.checkCancellation()
    guard let key = provider.keychainKey else { return }
    try KeychainHelper.delete(key: key)
  }
}

extension KeychainClassificationKeyStore: ClassificationKeyStore {}

actor MemoryClassificationKeyStore {
  private var values: [ClassificationProviderKind: String]
  private var failure: KeychainError?
  private var readFailure: KeychainError?
  private var probe: Result<Bool, KeychainError>?

  init(values: [ClassificationProviderKind: String] = [:]) { self.values = values }

  /// Applies to `add` and `remove`.
  func configureFailure(_ failure: KeychainError?) { self.failure = failure }
  func configureReadFailure(_ failure: KeychainError?) { readFailure = failure }
  /// Nil answers from the stored values.
  func configureProbe(_ result: Result<Bool, KeychainError>?) { probe = result }

  func load(provider: ClassificationProviderKind) throws(KeychainError) -> String? {
    if let readFailure { throw readFailure }
    return values[provider]
  }

  func exists(provider: ClassificationProviderKind) throws(KeychainError) -> Bool {
    guard let probe else { return values[provider] != nil }
    return try probe.get()
  }

  func add(_ value: String, provider: ClassificationProviderKind) throws {
    if let failure { throw failure }
    guard values[provider] == nil else { throw KeychainError.osStatus(errSecDuplicateItem) }
    values[provider] = value
  }

  func remove(provider: ClassificationProviderKind) throws {
    try Task.checkCancellation()
    if let failure { throw failure }
    values[provider] = nil
  }
}

extension MemoryClassificationKeyStore: ClassificationKeyStore {}

@Observable
final class ClassificationSettingsModel {
  enum KeyState { case loading, missing, saved }

  private(set) var provider: ClassificationProviderKind
  private(set) var keyState: KeyState
  private(set) var keyRevision = 0
  let isInert: Bool
  private let store: any ClassificationKeyStore

  var hasStoredKey: Bool { keyState == .saved }
  var isLoadingKey: Bool { keyState == .loading }

  init(
    provider: ClassificationProviderKind? = nil,
    store: (any ClassificationKeyStore)? = nil,
    isInert: Bool = HeadlessMode.isEnabled
  ) {
    self.isInert = isInert
    let selected = provider ?? (isInert ? .appleFM : .current)
    self.provider = selected
    self.store = store ?? (isInert ? MemoryClassificationKeyStore() : KeychainClassificationKeyStore())
    keyState = selected == .appleFM ? .missing : .loading
  }

  func select(_ provider: ClassificationProviderKind) {
    self.provider = provider
    keyRevision &+= 1
    if !isInert { ClassificationProviderKind.persist(provider) }
    keyState = provider == .appleFM ? .missing : .loading
  }

  func refreshKey() async {
    let selected = provider
    let revision = keyRevision
    guard selected != .appleFM else {
      keyState = .missing
      return
    }
    // A failed probe is not a missing key: "Edit" and Retry stay available.
    let exists = (try? await store.exists(provider: selected)) ?? true
    guard !Task.isCancelled, provider == selected, keyRevision == revision else { return }
    keyState = exists ? .saved : .missing
  }

  /// Must delete before the add: an update keeps the access list of the old
  /// item. When the delete completes and the add fails, no key is saved.
  func save(_ key: String, for provider: ClassificationProviderKind) async throws {
    try await store.remove(provider: provider)
    do {
      try await store.add(key, provider: provider)
    } catch {
      commitKeyChange(.missing, for: provider)
      throw error
    }
    commitKeyChange(.saved, for: provider)
  }

  func removeKey(for provider: ClassificationProviderKind) async throws {
    try await store.remove(provider: provider)
    commitKeyChange(.missing, for: provider)
  }

  /// A throw is a failed read: the caller must not show it as a missing key.
  func keyForModelList() async throws(KeychainError) -> String? {
    guard !isInert, provider == .openAI, hasStoredKey else { return nil }
    guard let key = try await store.load(provider: .openAI), !key.isEmpty else { return nil }
    return key
  }

  private func commitKeyChange(_ state: KeyState, for provider: ClassificationProviderKind) {
    if self.provider == provider { keyState = state }
    keyRevision &+= 1
  }
}
