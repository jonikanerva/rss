import Foundation
import Testing

@testable import Feeder

// MARK: - ClassificationEngine.buildProvider

/// The injected keychain-load closure keeps the test off the real keychain, so
/// no run pollutes the Security session or raises a prompt.
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
  private let categories = [CategoryDefinition(label: "tech", description: "Technology news")]

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

  /// `.appleFM` is the default kind. Resolving it must never call the
  /// keychain-load closure.
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

  // MARK: - Cloud providers without a stored key

  @Test(arguments: [ClassificationProviderKind.openAI, .vercel], [nil, ""] as [String?])
  func cloudKindWithoutKeyKeepsItsProviderAndNeedsKey(kind: ClassificationProviderKind, storedKey: String?) async {
    ClassificationProviderKind.persist(kind, in: defaults)
    var requestedKeys: [String] = []
    let provider = ClassificationEngine.buildProvider(defaults: defaults) { key in
      requestedKeys.append(key)
      return storedKey
    }

    // Compare with the constants, not `kind.keychainKey`: this test checks that mapping.
    switch kind {
    case .openAI:
      #expect(requestedKeys == [KeychainHelper.openAIAPIKeychainKey])
      #expect(provider is OpenAIClassificationProvider)
    case .vercel:
      #expect(requestedKeys == [KeychainHelper.vercelAPIKeychainKey])
      #expect(provider is VercelClassificationProvider)
    case .appleFM:
      Issue.record("Apple Foundation Models has no key to miss")
    }
    #expect(KeychainHelper.vercelAPIKeychainKey != KeychainHelper.openAIAPIKeychainKey)
    #expect(!(provider is AppleFMClassificationProvider))
    #expect(!(await provider.isAvailable))
    let error = await #expect(throws: (any Error).self) {
      try await provider.validate(categories: categories)
    }
    let failure = error as? any ClassificationFailure
    #expect(failure?.batchAbort == .needsKey)
    #expect(failure?.retryDisposition == .blocked)
  }

  // MARK: - OpenAI path with key

  @Test
  func openAIKindWithStoredKeyResolvesToOpenAIProvider() async {
    ClassificationProviderKind.persist(.openAI, in: defaults)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { key in
      // Verify the production code asked for the right keychain account.
      #expect(key == KeychainHelper.openAIAPIKeychainKey)
      return "sk-test-not-real"
    }

    #expect(provider.name == "OpenAI")
    #expect(await provider.isAvailable)
  }

  // MARK: - OpenAI model resolution

  /// An explicit model pick stored under `OpenAIModelSetting.userDefaultsKey`
  /// must reach the provider verbatim — `buildProvider` is the single
  /// resolution point, re-read per batch, so a Settings pick takes effect on
  /// the next polling cycle without any restart.
  @Test
  func buildProviderPassesStoredModelToOpenAIProvider() {
    ClassificationProviderKind.persist(.openAI, in: defaults)
    OpenAIModelSetting.persist("gpt-example-custom", in: defaults)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in "sk-test-not-real" }

    let openAIProvider = provider as? OpenAIClassificationProvider
    #expect(openAIProvider != nil)
    #expect(openAIProvider?.model == "gpt-example-custom")
  }

  /// With no model key stored, the provider must resolve to the current app
  /// default, so a user who never picked a model tracks a future default bump.
  @Test
  func buildProviderDefaultsToLunaWhenNoModelStored() {
    ClassificationProviderKind.persist(.openAI, in: defaults)
    #expect(defaults.string(forKey: OpenAIModelSetting.userDefaultsKey) == nil)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in "sk-test-not-real" }

    let openAIProvider = provider as? OpenAIClassificationProvider
    #expect(openAIProvider?.model == "gpt-5.6-luna")
  }
}
