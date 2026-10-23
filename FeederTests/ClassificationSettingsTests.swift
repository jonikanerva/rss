import Foundation
import Security
import Testing

@testable import Feeder

@MainActor
@Suite("Classification settings isolation")
struct ClassificationSettingsTests {
  @Test
  func keyReplacementAndRemovalFollowTheStore() async throws {
    let store = MemoryClassificationKeyStore()
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
    #expect(await store.load(provider: .vercel) == "replacement")
    try await settings.removeKey(for: .vercel)
    #expect(!settings.hasStoredKey)
    _ = settings.select(.appleFM)
    await settings.refreshKey()
    #expect(!settings.hasStoredKey)
    #expect(await store.load(provider: .vercel) == nil)
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
    _ = settings.select(.vercel)
    #expect(!settings.hasStoredKey)
  }
  @Test
  func saveUsesCapturedProviderAfterSelectionChanges() async throws {
    let store = MemoryClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    let editedProvider = settings.provider
    _ = settings.select(.appleFM)
    try await settings.save("vercel-test", for: editedProvider)
    await settings.refreshKey()
    #expect(settings.provider == .appleFM)
    #expect(!settings.hasStoredKey)
    #expect(await store.load(provider: .vercel) == "vercel-test")
    _ = settings.select(.vercel)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
  }
  @Test
  func rapidProviderSwitchesDiscardTheEarlierKeyLoad() async throws {
    let store = DelayedClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    let earlierLoad = Task { await settings.refreshKey() }
    try await waitUntil("key load starts") { await store.started }
    _ = settings.select(.appleFM)
    _ = settings.select(.vercel)
    await store.release()
    await earlierLoad.value
    #expect(settings.isLoadingKey)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
  }

  // MARK: - Keychain probe and read

  @Test(arguments: [true, false])
  func probeAloneDrivesTheSavedKeyState(itemExists: Bool) async {
    let store = RecordingClassificationKeyStore(probe: .success(itemExists))
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

// MARK: - Reclassification prompt

@MainActor
@Suite("Reclassification prompt")
struct ReclassificationPromptTests {
  @Test(arguments: [
    (ClassificationProviderKind.appleFM, "Apple Foundation Models"),
    (ClassificationProviderKind.vercel, "JEV through Vercel AI Gateway"),
  ])
  func providerPickAsksWithItsTarget(provider: ClassificationProviderKind, target: String) async {
    let store = MemoryClassificationKeyStore(values: [.vercel: "vercel-test"])
    let settings = ClassificationSettingsModel(
      provider: provider == .appleFM ? .vercel : .appleFM, store: store, isInert: true)
    #expect(settings.select(provider))
    #expect(settings.reclassificationPrompt == .afterKeyProbe)
    await settings.refreshKey()
    #expect(settings.reclassificationTarget == target)
  }

  @Test(arguments: [
    (VercelDecisionModel.decision1, "Decision-1 through Vercel AI Gateway"),
    (VercelDecisionModel.lunaDecisions, "GPT-6 Luna Decisions through Vercel AI Gateway"),
  ])
  func vercelModelPickWithASavedKeyAsksWithTheModelTarget(model: VercelDecisionModel, target: String) async {
    let store = MemoryClassificationKeyStore(values: [.vercel: "vercel-test"])
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    #expect(settings.vercelModel == .jev)
    #expect(!settings.selectVercelModel(.jev))
    #expect(settings.reclassificationPrompt == .idle)
    #expect(settings.selectVercelModel(model))
    #expect(settings.vercelModel == model)
    #expect(settings.reclassificationTarget == target)
    settings.dismissReclassificationPrompt()
    #expect(!settings.selectVercelModel(model))
    #expect(settings.reclassificationPrompt == .idle)
  }

  @Test
  func vercelModelPickWithoutASavedKeyNeverAsks() async {
    let settings = ClassificationSettingsModel(provider: .vercel, store: MemoryClassificationKeyStore(), isInert: true)
    await settings.refreshKey()
    #expect(settings.selectVercelModel(.decision1))
    #expect(settings.reclassificationPrompt == .idle)
  }

  @Test
  func failedProbeAsks() async {
    let store = MemoryClassificationKeyStore()
    await store.configureProbe(.failure(.osStatus(errSecInteractionNotAllowed)))
    let settings = ClassificationSettingsModel(provider: .appleFM, store: store, isInert: true)
    #expect(settings.select(.vercel))
    await settings.refreshKey()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
  }

  @Test
  func cloudPickWithoutASavedKeyNeverAsks() async {
    let settings = ClassificationSettingsModel(provider: .appleFM, store: MemoryClassificationKeyStore(), isInert: true)
    #expect(settings.select(.vercel))
    await settings.refreshKey()
    #expect(!settings.hasStoredKey)
    #expect(settings.reclassificationPrompt == .idle)
  }

  @Test
  func initialProbeWithAStoredKeyNeverAsks() async {
    let store = MemoryClassificationKeyStore(values: [.vercel: "vercel-test"])
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    #expect(settings.reclassificationPrompt == .idle)
    // Keep this step: without it, the test passes on the initial `idle` phase alone.
    #expect(settings.select(.appleFM))
    #expect(settings.select(.vercel))
    await settings.refreshKey()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
  }

  @Test
  func supersededProbeNeverAsks() async throws {
    let store = DelayedClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .appleFM, store: store, isInert: true)
    #expect(settings.select(.vercel))
    let supersededProbe = Task { await settings.refreshKey() }
    try await waitUntil("key probe starts") { await store.started }
    #expect(settings.select(.appleFM))
    #expect(settings.select(.vercel))
    await store.release()
    await supersededProbe.value
    #expect(settings.reclassificationTarget == nil)
    #expect(settings.reclassificationPrompt == .afterKeyProbe)
    await settings.refreshKey()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
  }

  @Test
  func cancelledProbeNeverAsks() async throws {
    let store = DelayedClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .appleFM, store: store, isInert: true)
    #expect(settings.select(.vercel))
    let probe = Task { await settings.refreshKey() }
    try await waitUntil("key probe starts") { await store.started }
    probe.cancel()
    await store.release()
    await probe.value
    #expect(settings.reclassificationTarget == nil)
    #expect(settings.reclassificationPrompt == .afterKeyProbe)
    #expect(settings.isLoadingKey)
    await settings.refreshKey()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
  }

  @Test
  func firstKeyAsksOnlyAfterTheKeyEditorCloses() async throws {
    let settings = ClassificationSettingsModel(provider: .appleFM, store: MemoryClassificationKeyStore(), isInert: true)
    #expect(settings.select(.vercel))
    await settings.refreshKey()
    #expect(settings.reclassificationPrompt == .idle)
    try await settings.save("vercel-test", for: .vercel)
    #expect(settings.reclassificationPrompt == .afterKeyEditorCloses)
    // The save bumps the key revision, so the view probes again while the
    // editor is open. That probe must not ask.
    await settings.refreshKey()
    #expect(settings.reclassificationPrompt == .afterKeyEditorCloses)
    settings.keyEditorClosed()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
  }

  @Test
  func replacementRemovalFailedAddAndCancelNeverAsk() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(true))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    #expect(settings.hasStoredKey)
    settings.keyEditorClosed()
    #expect(settings.reclassificationPrompt == .idle)

    try await settings.save("replacement", for: .vercel)
    settings.keyEditorClosed()
    #expect(settings.reclassificationPrompt == .idle)

    try await settings.removeKey(for: .vercel)
    settings.keyEditorClosed()
    #expect(!settings.hasStoredKey)
    #expect(settings.reclassificationPrompt == .idle)

    await store.configureAddFailure(.osStatus(errSecInteractionNotAllowed))
    await #expect(throws: KeychainError.self) { try await settings.save("first", for: .vercel) }
    settings.keyEditorClosed()
    #expect(settings.reclassificationPrompt == .idle)
  }

  @Test
  func retryAfterAFailedAddAsks() async throws {
    let store = RecordingClassificationKeyStore(probe: .success(true))
    let settings = ClassificationSettingsModel(provider: .vercel, store: store, isInert: true)
    await settings.refreshKey()
    await store.configureAddFailure(.osStatus(errSecInteractionNotAllowed))
    await #expect(throws: KeychainError.self) { try await settings.save("replacement", for: .vercel) }
    #expect(!settings.hasStoredKey)
    #expect(settings.reclassificationPrompt == .idle)
    await store.configureAddFailure(nil)
    try await settings.save("retry", for: .vercel)
    #expect(settings.reclassificationPrompt == .afterKeyEditorCloses)
    settings.keyEditorClosed()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
  }

  @Test
  func modelPickDuringAPendingProbeAsksWithTheNewModel() async throws {
    let store = DelayedClassificationKeyStore()
    let settings = ClassificationSettingsModel(provider: .appleFM, store: store, isInert: true)
    #expect(settings.select(.vercel))
    let probe = Task { await settings.refreshKey() }
    try await waitUntil("key probe starts") { await store.started }
    let revision = settings.keyRevision
    // A repeated pick of the selected provider must not restart the probe.
    #expect(!settings.select(.vercel))
    #expect(settings.keyRevision == revision)
    #expect(settings.selectVercelModel(.lunaDecisions))
    #expect(settings.reclassificationPrompt == .afterKeyProbe)
    await store.release()
    await probe.value
    #expect(settings.reclassificationTarget == "GPT-6 Luna Decisions through Vercel AI Gateway")
  }

  @Test
  func dismissOutsideShowingChangesNothing() async throws {
    let settings = ClassificationSettingsModel(provider: .appleFM, store: MemoryClassificationKeyStore(), isInert: true)
    #expect(settings.select(.vercel))
    settings.dismissReclassificationPrompt()
    #expect(settings.reclassificationPrompt == .afterKeyProbe)
    await settings.refreshKey()
    try await settings.save("vercel-test", for: .vercel)
    settings.dismissReclassificationPrompt()
    #expect(settings.reclassificationPrompt == .afterKeyEditorCloses)
    settings.keyEditorClosed()
    #expect(settings.reclassificationTarget == "JEV through Vercel AI Gateway")
    settings.dismissReclassificationPrompt()
    #expect(settings.reclassificationPrompt == .idle)
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
  func add(_ value: String, provider: ClassificationProviderKind) throws { throw KeychainError.osStatus(-1) }
  func remove(provider: ClassificationProviderKind) throws { throw KeychainError.osStatus(-1) }
}

extension DelayedClassificationKeyStore: ClassificationKeyStore {}

/// Records each store call in order and answers from its configuration, with
/// no Keychain access.
actor RecordingClassificationKeyStore {
  enum Call: Equatable {
    case exists(ClassificationProviderKind)
    case add(ClassificationProviderKind)
    case remove(ClassificationProviderKind)
  }

  private(set) var calls: [Call] = []
  private let probe: Result<Bool, KeychainError>
  private var addFailure: KeychainError?
  private var removeFailure: KeychainError?

  init(probe: Result<Bool, KeychainError>) {
    self.probe = probe
  }

  func configureAddFailure(_ failure: KeychainError?) { addFailure = failure }
  func configureRemoveFailure(_ failure: KeychainError?) { removeFailure = failure }

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
