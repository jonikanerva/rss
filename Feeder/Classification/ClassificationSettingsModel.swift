import Foundation

nonisolated protocol ClassificationKeyStore: Sendable {
  /// Follows the contract of `KeychainHelper.read(key:)`.
  func load(provider: ClassificationProviderKind) async throws(KeychainError) -> String?
  /// Follows the contract of `KeychainHelper.exists(key:)`.
  func exists(provider: ClassificationProviderKind) async throws(KeychainError) -> Bool
  func save(_ value: String, provider: ClassificationProviderKind) async throws
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

  func save(_ value: String, provider: ClassificationProviderKind) throws {
    try Task.checkCancellation()
    guard let key = provider.keychainKey else { return }
    // Security calls block and cannot be cancelled after entry; keep them on this actor.
    try KeychainHelper.save(key: key, value: value)
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

  /// Applies to `save` and `remove`.
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

  func save(_ value: String, provider: ClassificationProviderKind) throws {
    try Task.checkCancellation()
    if let failure { throw failure }
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

  func save(_ key: String, for provider: ClassificationProviderKind) async throws {
    try await store.save(key, provider: provider)
    if self.provider == provider { keyState = .saved }
    keyRevision &+= 1
  }

  func removeKey(for provider: ClassificationProviderKind) async throws {
    try await store.remove(provider: provider)
    if self.provider == provider { keyState = .missing }
    keyRevision &+= 1
  }

  /// A throw is a failed read: the caller must not show it as a missing key.
  func keyForModelList() async throws(KeychainError) -> String? {
    guard !isInert, provider == .openAI, hasStoredKey else { return nil }
    guard let key = try await store.load(provider: .openAI), !key.isEmpty else { return nil }
    return key
  }
}
