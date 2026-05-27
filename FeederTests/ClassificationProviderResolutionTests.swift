import Foundation
import Testing

@testable import Feeder

// MARK: - ClassificationEngine.buildProvider — keychain prompt avoidance

/// Bug-fix coverage for the "OpenAI key prompts twice on launch" regression:
/// when the user has selected `.openAI` in Settings but has not yet saved a
/// key, `buildProvider()` must fall back to the on-device Apple FM provider
/// rather than constructing an `OpenAIClassificationProvider` with an empty
/// key. The empty-key path used to fire a keychain access prompt during the
/// background classification runner's first batch, surfacing a system-modal
/// prompt to a user who had never opted into OpenAI.
///
/// The injected keychain-load closure replaces the production
/// `KeychainHelper.load` so the test never touches the real keychain — no
/// chance of polluting the per-process Security session or seeing a UI prompt
/// during test runs. Provider-kind state is stored in a per-test isolated
/// `UserDefaults(suiteName:)` instance — mirroring `SyncEngineTests`'s
/// per-test defaults injection — so the four cases in this suite can run in
/// parallel (Swift Testing's default) without clobbering each other's
/// `persist`/`current` reads through the shared `.standard` domain. The
/// production `ClassificationProviderKind.current` (zero-arg form) and the
/// `buildProvider(defaults:keychainLoad:)` overload that takes a
/// `UserDefaults` keep their existing production behavior — only the test
/// reads/writes are redirected.
@Suite("ClassificationEngine.buildProvider")
struct ClassificationProviderResolutionTests {
  // MARK: - Per-test isolation

  /// Per-test isolated `UserDefaults` instance. Built with a unique
  /// `suiteName` so reads/writes of `ClassificationProviderKind.userDefaultsKey`
  /// never touch `.standard`. Parallel suite execution (Swift Testing's
  /// default) cannot then flip another test's `.persist` selection between
  /// the persist and the `buildProvider` call. Pattern matches
  /// `SyncEngineTests.init`.
  private let defaults: UserDefaults

  init() {
    let id = "FeederTests.ClassificationProviderResolution.\(UUID().uuidString)"
    // `init(suiteName:)` returns nil for reserved names ("standard", "main",
    // etc.). A random UUID never hits one of those, so the force unwrap is
    // safe and surfaces an immediate test failure if Apple changes that
    // contract.
    guard let defaults = UserDefaults(suiteName: id) else {
      fatalError("Failed to construct test-isolated UserDefaults suite \(id)")
    }
    self.defaults = defaults
  }

  // MARK: - Apple FM path

  /// `.appleFM` is the default kind. The on-device provider is constructed
  /// without ever invoking the keychain — the closure must remain untouched.
  /// Counter-evidence: if a future refactor moves the keychain read up out
  /// of the `.openAI` branch, `loadCallCount` will tick and this test
  /// fails, surfacing the regression before it ships.
  @Test
  func appleFMKindSkipsKeychainEntirely() {
    ClassificationProviderKind.persist(.appleFM, in: defaults)

    var loadCallCount = 0
    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in
      loadCallCount += 1
      return "should-not-be-read"
    }

    #expect(loadCallCount == 0)
    #expect(provider.name == "Apple FM")
  }

  // MARK: - OpenAI path with empty/missing keys

  /// `.openAI` selected but the keychain returns `nil` (no item stored yet).
  /// Must fall back to Apple FM instead of constructing an OpenAI provider
  /// with an empty key — that would have produced an unauthenticated 401 at
  /// classify-time and, on the path that triggered the bug, an unwanted
  /// system-modal keychain access prompt at the *write* site.
  @Test
  func openAIKindWithMissingKeyFallsBackToAppleFM() {
    ClassificationProviderKind.persist(.openAI, in: defaults)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in nil }

    #expect(provider.name == "Apple FM")
  }

  /// `.openAI` selected but the keychain returns an empty string (which can
  /// legitimately happen if the user saved a blank value and then deleted
  /// the characters without dismissing Settings). Empty strings must be
  /// treated identically to "no key stored": fall back to Apple FM.
  @Test
  func openAIKindWithEmptyKeyFallsBackToAppleFM() {
    ClassificationProviderKind.persist(.openAI, in: defaults)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in "" }

    #expect(provider.name == "Apple FM")
  }

  // MARK: - OpenAI path with key

  /// Sanity check that the production path is still wired correctly: a
  /// non-empty stored key resolves to the OpenAI provider. Without this
  /// case the empty-key fallback could shadow a real bug if someone
  /// flipped the early-return condition inadvertently.
  @Test
  func openAIKindWithStoredKeyResolvesToOpenAIProvider() {
    ClassificationProviderKind.persist(.openAI, in: defaults)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { key in
      // Verify the production code asked for the right keychain account.
      #expect(key == KeychainHelper.openAIAPIKeychainKey)
      return "sk-test-not-real"
    }

    #expect(provider.name == "OpenAI")
  }
}
