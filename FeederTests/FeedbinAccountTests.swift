import Foundation
import Observation
import Security
import Testing

@testable import Feeder

// MARK: - Pure legacy read rule

/// No test here may call a `SecItem…` function or read `UserDefaults.standard`:
/// the test host runs in the owner's real app container.
@Suite("Feedbin legacy read rule")
struct FeedbinLegacyReadRuleTests {
  @Test(arguments: [nil, ""] as [String?])
  func noUsernameMeansNoAccountWithoutAPasswordRead(username: String?) throws {
    var passwordReads = 0
    let credentials = try KeychainFeedbinCredentialStore.legacyCredentials(username: username) {
      () throws(KeychainError) -> String? in
      passwordReads += 1
      return "secret"
    }
    #expect(credentials == nil)
    #expect(passwordReads == 0)
  }

  @Test(arguments: [KeychainError.osStatus(errSecAuthFailed), .osStatus(errSecUserCanceled), .encodingFailed])
  func failedPasswordReadRethrows(failure: KeychainError) {
    #expect(throws: failure) {
      try KeychainFeedbinCredentialStore.legacyCredentials(username: "reader@example.com") {
        () throws(KeychainError) -> String? in
        throw failure
      }
    }
  }

  @Test
  func missingPasswordMeansNoAccount() throws {
    #expect(try KeychainFeedbinCredentialStore.legacyCredentials(username: "reader@example.com") { nil } == nil)
  }

  @Test
  func storedPairComesBackUnchanged() throws {
    let credentials = try KeychainFeedbinCredentialStore.legacyCredentials(username: "reader@example.com") { "" }
    #expect(credentials == FeedbinCredentials(username: "reader@example.com", password: ""))
    #expect(credentials?.isComplete == false)
  }

  @Test
  func memoryStoreRejectsAnAddOverAnExistingAccount() async throws {
    let stored = FeedbinCredentials(username: "reader@example.com", password: "stored-secret")
    let store = MemoryFeedbinCredentialStore(credentials: stored)
    await #expect(throws: KeychainError.osStatus(errSecDuplicateItem)) {
      try await store.add(FeedbinCredentials(username: "new@example.com", password: "new-secret"))
    }
    #expect(try await store.load() == stored)
  }

  @Test
  func memoryStoreReadsItsLegacyValuesWithTheSameRule() async throws {
    let store = MemoryFeedbinCredentialStore(legacyUsername: "", legacyPassword: "old-secret")
    await store.configureLegacyPasswordReadFailure(.osStatus(errSecUserCanceled))
    #expect(try await store.loadLegacy() == nil)

    let complete = MemoryFeedbinCredentialStore(legacyUsername: "old@example.com", legacyPassword: "old-secret")
    #expect(try await complete.loadLegacy() == FeedbinCredentials(username: "old@example.com", password: "old-secret"))
    #expect(try await complete.load() == nil)
    await complete.configureLegacyPasswordReadFailure(.osStatus(errSecUserCanceled))
    await #expect(throws: KeychainError.osStatus(errSecUserCanceled)) { try await complete.loadLegacy() }

    await complete.removeLegacy()
    #expect(try await complete.loadLegacy() == nil)
  }
}

// MARK: - Account phase and save

@MainActor
@Suite("Feedbin account")
struct FeedbinAccountTests {
  nonisolated private static let stored = FeedbinCredentials(username: "reader@example.com", password: "stored-secret")
  nonisolated private static let replacement = FeedbinCredentials(username: "new@example.com", password: "new-secret")
  nonisolated private static let legacy = FeedbinCredentials(username: "old@example.com", password: "old-secret")

  /// Per-test `UserDefaults`, so the engine's sync keys never reach the
  /// standard domain, which is the owner's real one in the test host.
  private let defaults: UserDefaults

  init() {
    let id = "FeederTests.FeedbinAccount.\(UUID().uuidString)"
    // A random UUID is never a reserved suite name.
    guard let defaults = UserDefaults(suiteName: id) else {
      fatalError("Failed to construct test-isolated UserDefaults suite \(id)")
    }
    self.defaults = defaults
  }

  private func makeEngine(
    store: any FeedbinCredentialStore,
    account: FeedbinAccountPhase = .checking,
    factory: RecordingClientFactory = RecordingClientFactory()
  ) -> SyncEngine {
    SyncEngine(defaults: defaults, credentialStore: store, account: account, makeClient: factory.make)
  }

  private func save(_ credentials: FeedbinCredentials, with engine: SyncEngine) async throws -> Bool {
    try await engine.saveAccount(username: credentials.username, password: credentials.password)
  }

  /// Proves which client the engine holds: only the installed client receives
  /// the queued read-state push.
  private func pushReadState(through engine: SyncEngine) async {
    engine.queueReadIDs([42])
    await engine.pushPendingReads()
  }

  // MARK: Launch read

  @Test
  func launchReadSignsInWithTheClientBuiltFromTheStoredPair() async {
    let client = FakeFeedbinClient()
    let factory = RecordingClientFactory { _ in client }
    let engine = makeEngine(store: MemoryFeedbinCredentialStore(credentials: Self.stored), factory: factory)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .signedIn(username: Self.stored.username))
    #expect(factory.builtFor == [Self.stored])
    await pushReadState(through: engine)
    #expect(await client.deleteUnreadEntriesCallLog == [[42]])
  }

  @Test(
    arguments: [
      nil,
      FeedbinCredentials(username: "reader@example.com", password: ""),
      FeedbinCredentials(username: "", password: "stored-secret"),
    ] as [FeedbinCredentials?])
  func launchReadWithoutACompletePairFindsNoAccount(stored: FeedbinCredentials?) async {
    let factory = RecordingClientFactory()
    let engine = makeEngine(store: MemoryFeedbinCredentialStore(credentials: stored), factory: factory)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .noAccount)
    #expect(factory.builtFor.isEmpty)
  }

  @Test(arguments: [KeychainError.osStatus(errSecUserCanceled), .osStatus(errSecAuthFailed), .encodingFailed])
  func failedLaunchReadIsUnreadableNeverNoAccount(failure: KeychainError) async {
    let store = MemoryFeedbinCredentialStore(credentials: Self.stored)
    await store.configureLoadFailure(failure)
    let factory = RecordingClientFactory()
    let engine = makeEngine(store: store, factory: factory)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .unreadable)
    #expect(factory.builtFor.isEmpty)
  }

  @Test(arguments: [FeedbinAccountPhase.noAccount, .signedIn(username: "reader@example.com"), .unreadable])
  func launchReadSkipsEveryPhaseButChecking(phase: FeedbinAccountPhase) async {
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored))
    let engine = makeEngine(store: store, account: phase)

    await engine.loadAccountAtLaunch()

    #expect(await store.calls.isEmpty)
    #expect(engine.account == phase)
  }

  @Test
  func unusedPhaseNeverTouchesTheStoreOrTheFactory() async throws {
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored))
    let factory = RecordingClientFactory()
    let engine = makeEngine(store: store, account: .unused, factory: factory)

    await engine.loadAccountAtLaunch()
    await engine.retryAccount()
    await engine.sync()
    let saved = try await save(Self.replacement, with: engine)

    #expect(!saved)
    #expect(await store.calls.isEmpty)
    #expect(factory.builtFor.isEmpty)
    #expect(engine.account == .unused)
  }

  @Test
  func concurrentReadsShareOneStoreCall() async throws {
    let gate = AsyncGate()
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored), loadGate: gate)
    let engine = makeEngine(store: store)
    let first = Task { await engine.loadAccountAtLaunch() }
    try await waitUntil("the first read reaches the store") { await store.calls == [.load] }

    let marker = StartMarker()
    let launchRead = Task {
      marker.mark()
      await engine.loadAccountAtLaunch()
    }
    let retry = Task {
      marker.mark()
      await engine.retryAccount()
    }
    try await waitUntil("the joining reads start") { await marker.marks == 2 }
    gate.open()
    await first.value
    await launchRead.value
    await retry.value

    #expect(await store.calls == [.load])
    #expect(engine.account == .signedIn(username: Self.stored.username))
  }

  /// The launch read starts in `.checking`, so observers see no change until
  /// the phase resolves.
  @Test
  func phaseNotifiesObserversOnlyWhenItsValueChanges() async throws {
    let gate = AsyncGate()
    let store = RecordingFeedbinCredentialStore(loadResult: .success(nil), loadGate: gate)
    let engine = makeEngine(store: store)
    let changed = ChangeFlag()
    withObservationTracking {
      _ = engine.account
    } onChange: {
      changed.set()
    }

    let read = Task { await engine.loadAccountAtLaunch() }
    try await waitUntil("the read reaches the store") { await store.calls == [.load] }
    #expect(!changed.isSet)

    gate.open()
    await read.value
    #expect(changed.isSet)
    #expect(engine.account == .noAccount)
  }

  // MARK: Retry

  @Test
  func retryFromUnreadableSignsInWhenTheReadSucceeds() async {
    let client = FakeFeedbinClient()
    let engine = makeEngine(
      store: MemoryFeedbinCredentialStore(credentials: Self.stored), account: .unreadable,
      factory: RecordingClientFactory { _ in client })

    await engine.retryAccount()

    #expect(engine.account == .signedIn(username: Self.stored.username))
    await pushReadState(through: engine)
    #expect(await client.deleteUnreadEntriesCallLog == [[42]])
  }

  @Test
  func failedRetryStaysUnreadableAfterOneRead() async {
    let store = RecordingFeedbinCredentialStore(loadResult: .failure(.osStatus(errSecAuthFailed)))
    let engine = makeEngine(store: store, account: .unreadable)

    await engine.retryAccount()

    #expect(engine.account == .unreadable)
    #expect(await store.calls == [.load])
  }

  @Test(arguments: [FeedbinAccountPhase.checking, .noAccount, .signedIn(username: "reader@example.com")])
  func retrySkipsEveryPhaseButUnreadable(phase: FeedbinAccountPhase) async {
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored))
    let engine = makeEngine(store: store, account: phase)

    await engine.retryAccount()

    #expect(await store.calls.isEmpty)
    #expect(engine.account == phase)
  }

  @Test
  func syncInTheUnreadablePhaseReadsTheAccountOnce() async {
    let store = RecordingFeedbinCredentialStore(loadResult: .failure(.osStatus(errSecUserCanceled)))
    let engine = makeEngine(store: store, account: .unreadable)

    await engine.sync()
    #expect(await store.calls == [.load])
    #expect(engine.account == .unreadable)

    await store.setLoadResult(.success(Self.stored))
    await engine.sync()
    #expect(await store.calls == [.load, .load])
    #expect(engine.account == .signedIn(username: Self.stored.username))

    await engine.sync()
    #expect(await store.calls == [.load, .load])
  }

  // MARK: Save

  @Test
  func saveVerifiesRemovesAddsThenRemovesTheLegacyValues() async throws {
    let client = FakeFeedbinClient()
    let store = RecordingFeedbinCredentialStore()
    let factory = RecordingClientFactory { _ in client }
    let engine = makeEngine(store: store, account: .noAccount, factory: factory)

    #expect(try await save(Self.replacement, with: engine))

    #expect(await client.verifyCallCount == 1)
    #expect(await store.calls == [.remove, .add(Self.replacement), .removeLegacy])
    #expect(factory.builtFor == [Self.replacement])
    #expect(engine.account == .signedIn(username: Self.replacement.username))
  }

  @Test
  func rejectedCredentialsMakeNoStoreCall() async throws {
    let client = FakeFeedbinClient()
    await client.setVerifyResult(.success(false))
    let store = RecordingFeedbinCredentialStore()
    let engine = makeEngine(store: store, account: .noAccount, factory: RecordingClientFactory { _ in client })

    #expect(try await !save(Self.replacement, with: engine))

    #expect(await store.calls.isEmpty)
    #expect(engine.account == .noAccount)
  }

  @Test
  func networkFailureDuringVerifyThrowsWithoutAStoreCall() async {
    let client = FakeFeedbinClient()
    await client.setVerifyResult(.failure(URLError(.notConnectedToInternet)))
    let store = RecordingFeedbinCredentialStore()
    let engine = makeEngine(store: store, account: .unreadable, factory: RecordingClientFactory { _ in client })

    await #expect(throws: URLError.self) { try await save(Self.replacement, with: engine) }

    #expect(await store.calls.isEmpty)
    #expect(engine.account == .unreadable)
  }

  @Test
  func failedRemoveKeepsThePhaseAndTheRunningClient() async throws {
    let running = FakeFeedbinClient()
    let candidate = FakeFeedbinClient()
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored))
    let factory = RecordingClientFactory { $0 == Self.stored ? running : candidate }
    let engine = makeEngine(store: store, factory: factory)
    await engine.loadAccountAtLaunch()
    await store.configureRemoveFailure(.osStatus(errSecInvalidOwnerEdit))

    await #expect(throws: KeychainError.osStatus(errSecInvalidOwnerEdit)) {
      try await save(Self.replacement, with: engine)
    }

    #expect(engine.account == .signedIn(username: Self.stored.username))
    #expect(await store.calls == [.load, .remove])
    await pushReadState(through: engine)
    #expect(await running.deleteUnreadEntriesCallLog == [[42]])
    #expect(await candidate.deleteUnreadEntriesCallLog.isEmpty)
  }

  @Test
  func failedAddAfterACompletedRemoveSignsOutAndStopsSync() async throws {
    let running = FakeFeedbinClient()
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored))
    let factory = RecordingClientFactory { $0 == Self.stored ? running : FakeFeedbinClient() }
    let engine = makeEngine(store: store, factory: factory)
    await engine.loadAccountAtLaunch()
    // Without a writer the backfill task ends at once, but the engine holds it
    // until `stopPeriodicSync()` clears it.
    engine.refetchHistory()
    #expect(engine.hasScheduledSyncWork)
    await store.configureAddFailure(.osStatus(errSecInteractionNotAllowed))

    await #expect(throws: KeychainError.osStatus(errSecInteractionNotAllowed)) {
      try await save(Self.replacement, with: engine)
    }

    #expect(engine.account == .noAccount)
    #expect(!engine.hasScheduledSyncWork)
    #expect(await store.calls == [.load, .remove, .add(Self.replacement)])
    await pushReadState(through: engine)
    #expect(await running.deleteUnreadEntriesCallLog.isEmpty)
  }

  @Test
  func saveWhileSignedInSwitchesTheNextSyncToTheNewClient() async throws {
    let old = FakeFeedbinClient()
    let new = FakeFeedbinClient()
    let store = MemoryFeedbinCredentialStore(credentials: Self.stored)
    let engine = makeEngine(store: store, factory: RecordingClientFactory { $0 == Self.stored ? old : new })
    engine.attachWriter(try await DataWriterTestSupport.makeWriter())
    await engine.loadAccountAtLaunch()

    #expect(try await save(Self.replacement, with: engine))
    await engine.sync()

    #expect(await new.fetchEntryPagesCallCount == 1)
    #expect(await old.fetchEntryPagesCallCount == 0)
    #expect(try await store.load() == Self.replacement)
    #expect(engine.account == .signedIn(username: Self.replacement.username))
  }

  @Test
  func saveWaitsForTheReadInFlight() async throws {
    let gate = AsyncGate()
    let client = FakeFeedbinClient()
    let store = RecordingFeedbinCredentialStore(loadResult: .success(nil), loadGate: gate)
    let engine = makeEngine(store: store, factory: RecordingClientFactory { _ in client })
    let read = Task { await engine.loadAccountAtLaunch() }
    try await waitUntil("the read reaches the store") { await store.calls == [.load] }

    let marker = StartMarker()
    let saving = Task {
      marker.mark()
      return try await save(Self.replacement, with: engine)
    }
    try await waitUntil("the save starts") { await marker.marks == 1 }
    #expect(await client.verifyCallCount == 0)

    gate.open()
    await read.value
    #expect(try await saving.value)
    #expect(await store.calls == [.load, .loadLegacy, .remove, .add(Self.replacement), .removeLegacy])
    #expect(engine.account == .signedIn(username: Self.replacement.username))
  }

  @Test
  func readDuringASaveDoesNothing() async throws {
    let gate = AsyncGate()
    let client = FakeFeedbinClient()
    await client.holdVerification(until: gate)
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored))
    let engine = makeEngine(store: store, account: .unreadable, factory: RecordingClientFactory { _ in client })
    let saving = Task { try await save(Self.replacement, with: engine) }
    try await waitUntil("the save reaches verification") { await client.verifyCallCount == 1 }

    await engine.retryAccount()
    await engine.sync()
    #expect(await store.calls.isEmpty)

    gate.open()
    #expect(try await saving.value)
    #expect(await store.calls == [.remove, .add(Self.replacement), .removeLegacy])
    #expect(engine.account == .signedIn(username: Self.replacement.username))
  }

  @Test
  func secondSaveWaitsForTheFirst() async throws {
    let gate = AsyncGate()
    let first = FakeFeedbinClient()
    await first.holdVerification(until: gate)
    let second = FakeFeedbinClient()
    let store = RecordingFeedbinCredentialStore()
    let factory = RecordingClientFactory { $0 == Self.stored ? first : second }
    let engine = makeEngine(store: store, account: .noAccount, factory: factory)
    let firstSave = Task { try await save(Self.stored, with: engine) }
    try await waitUntil("the first save reaches verification") { await first.verifyCallCount == 1 }

    let marker = StartMarker()
    let secondSave = Task {
      marker.mark()
      return try await save(Self.replacement, with: engine)
    }
    try await waitUntil("the second save starts") { await marker.marks == 1 }
    #expect(await second.verifyCallCount == 0)

    gate.open()
    #expect(try await firstSave.value)
    #expect(try await secondSave.value)
    #expect(
      await store.calls == [
        .remove, .add(Self.stored), .removeLegacy, .remove, .add(Self.replacement), .removeLegacy,
      ])
    #expect(engine.account == .signedIn(username: Self.replacement.username))
  }

  // MARK: Migration

  private func makeLegacyStore(password: String? = Self.legacy.password) -> MemoryFeedbinCredentialStore {
    MemoryFeedbinCredentialStore(legacyUsername: Self.legacy.username, legacyPassword: password)
  }

  @Test
  func existingItemIsTheOnlyRead() async {
    let store = RecordingFeedbinCredentialStore(loadResult: .success(Self.stored), legacyResult: .success(Self.legacy))
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(await store.calls == [.load])
    #expect(engine.account == .signedIn(username: Self.stored.username))
  }

  @Test
  func incompleteItemFindsNoAccountWithoutALegacyRead() async {
    let incomplete = FeedbinCredentials(username: Self.stored.username, password: "")
    let store = RecordingFeedbinCredentialStore(loadResult: .success(incomplete), legacyResult: .success(Self.legacy))
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(await store.calls == [.load])
    #expect(engine.account == .noAccount)
  }

  @Test
  func unreadableItemIsUnreadableWithoutALegacyRead() async {
    let store = RecordingFeedbinCredentialStore(
      loadResult: .failure(.osStatus(errSecUserCanceled)), legacyResult: .success(Self.legacy))
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(await store.calls == [.load])
    #expect(engine.account == .unreadable)
  }

  @Test
  func completeLegacyPairMovesIntoTheItemWithoutContactingFeedbin() async {
    let client = FakeFeedbinClient()
    let factory = RecordingClientFactory { _ in client }
    let store = RecordingFeedbinCredentialStore(legacyResult: .success(Self.legacy))
    let engine = makeEngine(store: store, factory: factory)

    await engine.loadAccountAtLaunch()

    #expect(await store.calls == [.load, .loadLegacy, .add(Self.legacy), .removeLegacy])
    #expect(engine.account == .signedIn(username: Self.legacy.username))
    #expect(factory.builtFor == [Self.legacy])
    #expect(await client.verifyCallCount == 0)
  }

  @Test
  func migrationLeavesOnlyTheItem() async throws {
    let store = makeLegacyStore()
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .signedIn(username: Self.legacy.username))
    #expect(try await store.load() == Self.legacy)
    #expect(try await store.loadLegacy() == nil)
  }

  @Test
  func failedMigrationAddSignsInFromTheLegacyPairAndTheNextLaunchMovesIt() async {
    let client = FakeFeedbinClient()
    let factory = RecordingClientFactory { _ in client }
    let store = RecordingFeedbinCredentialStore(legacyResult: .success(Self.legacy))
    await store.configureAddFailure(.osStatus(errSecInteractionNotAllowed))
    let engine = makeEngine(store: store, factory: factory)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .signedIn(username: Self.legacy.username))
    #expect(await store.calls == [.load, .loadLegacy, .add(Self.legacy)])
    #expect(factory.builtFor == [Self.legacy])
    #expect(await client.verifyCallCount == 0)

    await store.configureAddFailure(nil)
    let nextLaunch = makeEngine(store: store)
    await nextLaunch.loadAccountAtLaunch()

    #expect(nextLaunch.account == .signedIn(username: Self.legacy.username))
    #expect(
      await store.calls == [
        .load, .loadLegacy, .add(Self.legacy), .load, .loadLegacy, .add(Self.legacy), .removeLegacy,
      ])
  }

  @Test
  func deniedLegacyReadIsUnreadableAndKeepsTheLegacyValues() async throws {
    let store = makeLegacyStore()
    await store.configureLegacyPasswordReadFailure(.osStatus(errSecUserCanceled))
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .unreadable)
    #expect(try await store.load() == nil)
    await store.configureLegacyPasswordReadFailure(nil)
    #expect(try await store.loadLegacy() == Self.legacy)

    await engine.retryAccount()

    #expect(engine.account == .signedIn(username: Self.legacy.username))
    #expect(try await store.load() == Self.legacy)
    #expect(try await store.loadLegacy() == nil)
  }

  @Test(arguments: [nil, ""] as [String?])
  func legacyUsernameWithoutAPasswordFindsNoAccount(password: String?) async throws {
    let factory = RecordingClientFactory()
    let store = makeLegacyStore(password: password)
    let engine = makeEngine(store: store, factory: factory)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .noAccount)
    #expect(try await store.load() == nil)
    #expect(factory.builtFor.isEmpty)
  }

  /// A password read would throw and make the phase unreadable.
  @Test(arguments: [nil, ""] as [String?])
  func missingLegacyUsernameNeverReadsThePassword(username: String?) async {
    let store = MemoryFeedbinCredentialStore(legacyUsername: username, legacyPassword: Self.legacy.password)
    await store.configureLegacyPasswordReadFailure(.osStatus(errSecUserCanceled))
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .noAccount)
  }

  /// An older build writes only the legacy values, so after a return from it
  /// both storages hold an account.
  @Test
  func itemWinsAfterARollbackAndTheNextSaveRemovesTheLegacyValues() async throws {
    let store = MemoryFeedbinCredentialStore(
      credentials: Self.stored, legacyUsername: Self.legacy.username, legacyPassword: Self.legacy.password)
    let engine = makeEngine(store: store)

    await engine.loadAccountAtLaunch()

    #expect(engine.account == .signedIn(username: Self.stored.username))
    #expect(try await store.loadLegacy() == Self.legacy)

    #expect(try await save(Self.replacement, with: engine))

    #expect(try await store.load() == Self.replacement)
    #expect(try await store.loadLegacy() == nil)
  }

  // MARK: Settings rows

  @Test
  func settingsRowsFollowThePhase() {
    let checking = FeedbinAccountRows(phase: .checking)
    #expect(checking.email == "Checking…" && checking.isPlaceholder && !checking.isEditEnabled)

    let noAccount = FeedbinAccountRows(phase: .noAccount)
    #expect(noAccount.email == "Not configured" && noAccount.password == "Not set")
    #expect(noAccount.isPlaceholder && noAccount.isEditEnabled)

    let unused = FeedbinAccountRows(phase: .unused)
    #expect(unused.email == "Not configured" && !unused.isEditEnabled)

    let signedIn = FeedbinAccountRows(phase: .signedIn(username: Self.stored.username))
    #expect(signedIn.email == Self.stored.username && signedIn.password == "•••••")
    #expect(!signedIn.isPlaceholder && signedIn.isEditEnabled)

    let unreadable = FeedbinAccountRows(phase: .unreadable)
    #expect(unreadable.email == "Could not read from Keychain" && unreadable.isEditEnabled)
  }
}
