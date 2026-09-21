import Foundation

nonisolated protocol ClassificationKeyStore: Sendable {
  func load(provider: ClassificationProviderKind) async -> String?
  func save(_ value: String, provider: ClassificationProviderKind) async throws
  func remove(provider: ClassificationProviderKind) async throws
}

actor KeychainClassificationKeyStore {
  func load(provider: ClassificationProviderKind) -> String? {
    guard !Task.isCancelled else { return nil }
    return provider.keychainKey.flatMap { KeychainHelper.load(key: $0) }
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

  init(values: [ClassificationProviderKind: String] = [:]) { self.values = values }

  func configureFailure(_ failure: KeychainError?) { self.failure = failure }
  func load(provider: ClassificationProviderKind) -> String? { values[provider] }

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
    let key = await store.load(provider: selected)
    guard !Task.isCancelled, provider == selected, keyRevision == revision else { return }
    keyState = (key ?? "").isEmpty ? .missing : .saved
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

  func keyForModelList() async -> String? {
    guard !isInert, provider == .openAI, hasStoredKey else { return nil }
    return await store.load(provider: .openAI)
  }
}
