import Foundation
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
    #expect(await settings.keyForModelList() == nil)
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
  func headlessDefaultIsInertAndNeverReadsCloudSettings() async {
    let settings = ClassificationSettingsModel(isInert: true)
    #expect(settings.provider == .appleFM)
    #expect(!settings.hasStoredKey)
    settings.select(.vercel)
    #expect(!settings.hasStoredKey)
    #expect(await settings.keyForModelList() == nil)
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
}

actor DelayedClassificationKeyStore {
  private let gate: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private(set) var started = false

  init() { (gate, continuation) = AsyncStream<Void>.makeStream() }

  func load(provider: ClassificationProviderKind) async -> String? {
    started = true
    for await _ in gate { break }
    return "fake-key"
  }

  func release() { continuation.finish() }
  func save(_ value: String, provider: ClassificationProviderKind) throws { throw KeychainError.osStatus(-1) }
  func remove(provider: ClassificationProviderKind) throws { throw KeychainError.osStatus(-1) }
}

extension DelayedClassificationKeyStore: ClassificationKeyStore {}
