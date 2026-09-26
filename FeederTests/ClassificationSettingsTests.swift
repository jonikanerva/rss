import Foundation
import Security
import Testing

@testable import Feeder

@MainActor
@Suite("Classification settings isolation")
struct ClassificationSettingsTests {
  @Test
  func keysAndReplacementsStayWithTheirProvider() async throws {
    let store = MemoryClassificationKeyStore(values: [.openAI: "openai-test"])
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    #expect(settings.isLoadingKey)
    await settings.refreshKey()
    #expect(!settings.isLoadingKey)
    #expect(!settings.hasStoredKey)
    try await settings.save("vercel-test", for: .vercel)
    #expect(settings.hasStoredKey)
    let firstRevision = settings.keyRevision
    try await settings.save("replacement", for: .vercel)
    #expect(settings.keyRevision > firstRevision)
    #expect(await store.load(provider: .openAI) == "openai-test")
    #expect(await store.load(provider: .vercel) == "replacement")
    try await settings.removeKey(for: .vercel)
    #expect(!settings.hasStoredKey)
    settings.select(.openAI)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    #expect(await store.load(provider: .openAI) == "openai-test")
    #expect(try await settings.keyForModelList() == nil)
  }

  @Test
  func failedSaveAndRemoveDoNotClaimSuccess() async throws {
    let store = MemoryClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await store.configureFailure(.osStatus(-1))
    await #expect(throws: KeychainError.self) { try await settings.save("test", for: .vercel) }
    #expect(!settings.hasStoredKey)
    #expect(settings.keyRevision == 0)
    await store.configureFailure(nil)
    try await settings.save("test", for: .vercel)
    await store.configureFailure(.osStatus(-1))
    await #expect(throws: KeychainError.self) { try await settings.removeKey(for: .vercel) }
    #expect(settings.hasStoredKey)
    #expect(settings.keyRevision == 1)
  }

  @Test
  func headlessDefaultIsInertAndNeverReadsCloudSettings() async throws {
    let settings = ClassificationSettingsModel(isInert: true)
    #expect(settings.provider == .appleFM)
    #expect(!settings.hasStoredKey)
    settings.select(.vercel)
    #expect(!settings.hasStoredKey)
    #expect(try await settings.keyForModelList() == nil)
  }
  @Test
  func saveUsesCapturedProviderAfterSelectionChanges() async throws {
    let store = MemoryClassificationKeyStore(values: [.openAI: "openai-test"])
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    let editedProvider = settings.provider
    settings.select(.openAI)
    try await settings.save("vercel-test", for: editedProvider)
    await settings.refreshKey()
    #expect(settings.provider == .openAI)
    #expect(settings.hasStoredKey)
    #expect(await store.load(provider: .openAI) == "openai-test")
    #expect(await store.load(provider: .vercel) == "vercel-test")
  }
  @Test
  func rapidProviderSwitchesDiscardTheEarlierKeyLoad() async throws {
    let store = DelayedClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    let earlierLoad = Task { await settings.refreshKey() }
    try await waitUntil("key load starts") { await store.started }
    settings.select(.openAI)
    settings.select(.vercel)
    await store.release()
    await earlierLoad.value
    #expect(settings.isLoadingKey)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
  }

  // MARK: - Keychain probe and read

  @Test(arguments: [true, false])
  func probeAloneDrivesTheSavedKeyState(itemExists: Bool) async {
    let store = RecordingClassificationKeyStore(probe: .success(itemExists), read: .failure(.osStatus(errSecAuthFailed)))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    #expect(settings.hasStoredKey == itemExists)
    #expect(!settings.isLoadingKey)
    #expect(await store.calls == [.exists(.vercel)])
  }

  @Test(arguments: [KeychainError.osStatus(errSecInteractionNotAllowed), .osStatus(errSecAuthFailed), .encodingFailed])
  func failedProbeKeepsEditAndRetryAvailable(failure: KeychainError) async {
    let store = MemoryClassificationKeyStore()
    await store.configureProbe(.failure(failure))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    #expect(!settings.isLoadingKey)
  }

  @Test
  func failedModelListReadThrowsAfterOneRead() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(true), read: .failure(.osStatus(errSecAuthFailed)))
    let settings = ClassificationSettingsModel(provider: .openAI, store: store, isInert: false)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    await #expect(throws: KeychainError.osStatus(errSecAuthFailed)) { try await settings.keyForModelList() }
    #expect(await store.calls == [.exists(.openAI), .load(.openAI)])
  }

  @Test
  func unreadableKeyModelLineDoesNotClaimAMissingKey() {
    #expect(ModelListState.keyUnreadable == .failed(reason: "Models load when the API key can be read."))
    #expect(ModelListState.keyUnreadable != .needsKey)
  }

  @Test
  func readableKeyReachesTheModelList() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(true), read: .success("sk-test"))
    let settings = ClassificationSettingsModel(provider: .openAI, store: store, isInert: false)
    await settings.refreshKey()
    #expect(try await settings.keyForModelList() == "sk-test")
  }

  @Test
  func emptyStoredKeyGivesTheModelListNoKey() async throws {
    let store = MemoryClassificationKeyStore(values: [.openAI: ""])
    let settings = ClassificationSettingsModel(provider: .openAI, store: store, isInert: false)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    #expect(try await settings.keyForModelList() == nil)
  }

  // MARK: - Delete-then-add save

  @Test
  func everySaveDeletesTheOldItemBeforeItAdds() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(false))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    try await settings.save("first", for: .vercel)
    try await settings.save("second", for: .vercel)
    #expect(await store.calls == [.remove(.vercel), .add(.vercel), .remove(.vercel), .add(.vercel)])
    #expect(settings.hasStoredKey)
  }

  @Test
  func failedAddAfterACompletedDeleteLeavesNoKeySaved() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(true))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    await store.configureAddFailure(.osStatus(errSecInteractionNotAllowed))
    let revision = settings.keyRevision
    await #expect(throws: KeychainError.osStatus(errSecInteractionNotAllowed)) { try await settings.save("new", for: .vercel) }
    #expect(!settings.hasStoredKey)
    #expect(settings.keyRevision > revision)
    #expect(await store.calls == [.exists(.vercel), .remove(.vercel), .add(.vercel)])
  }

  @Test
  func failedDeleteAddsNothingAndKeepsTheSavedKey() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(true))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    await store.configureRemoveFailure(.osStatus(errSecInvalidOwnerEdit))
    let revision = settings.keyRevision
    await #expect(throws: KeychainError.osStatus(errSecInvalidOwnerEdit)) { try await settings.save("new", for: .vercel) }
    #expect(settings.hasStoredKey)
    #expect(settings.keyRevision == revision)
    #expect(await store.calls == [.exists(.vercel), .remove(.vercel)])
  }

  @Test
  func memoryStoreRejectsAnAddOverAnExistingKey() async throws {
    let store = MemoryClassificationKeyStore(values: [.vercel: "old"])
    await #expect(throws: KeychainError.osStatus(errSecDuplicateItem)) { try await store.add("new", provider: .vercel) }
    #expect(await store.load(provider: .vercel) == "old")
  }
}

actor DelayedClassificationKeyStore {
  private let gate: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private(set) var started = false

  init() { (gate, continuation) = AsyncStream<Void>.makeStream() }

  func exists(provider: ClassificationProviderKind) async -> Bool {
    started = true
    for await _ in gate { break }
    return true
  }

  func release() { continuation.finish() }
  func load(provider: ClassificationProviderKind) -> String? { "fake-key" }
  func add(_ value: String, provider: ClassificationProviderKind) throws { throw KeychainError.osStatus(-1) }
  func remove(provider: ClassificationProviderKind) throws { throw KeychainError.osStatus(-1) }
}

extension DelayedClassificationKeyStore: ClassificationKeyStore {}

/// Records each store call in order and answers from its configuration, with
/// no Keychain access.
actor RecordingClassificationKeyStore {
  enum Call: Equatable {
    case load(ClassificationProviderKind)
    case exists(ClassificationProviderKind)
    case add(ClassificationProviderKind)
    case remove(ClassificationProviderKind)
  }

  private(set) var calls: [Call] = []
  private let probe: Result<Bool, KeychainError>
  private let read: Result<String?, KeychainError>
  private var addFailure: KeychainError?
  private var removeFailure: KeychainError?

  init(probe: Result<Bool, KeychainError>, read: Result<String?, KeychainError> = .success(nil)) {
    self.probe = probe
    self.read = read
  }

  func configureAddFailure(_ failure: KeychainError?) { addFailure = failure }
  func configureRemoveFailure(_ failure: KeychainError?) { removeFailure = failure }

  func load(provider: ClassificationProviderKind) throws(KeychainError) -> String? {
    calls.append(.load(provider))
    return try read.get()
  }

  func exists(provider: ClassificationProviderKind) throws(KeychainError) -> Bool {
    calls.append(.exists(provider))
    return try probe.get()
  }

  func add(_ value: String, provider: ClassificationProviderKind) throws {
    calls.append(.add(provider))
    if let addFailure { throw addFailure }
  }

  func remove(provider: ClassificationProviderKind) throws {
    calls.append(.remove(provider))
    if let removeFailure { throw removeFailure }
  }
}

extension RecordingClassificationKeyStore: ClassificationKeyStore {}
