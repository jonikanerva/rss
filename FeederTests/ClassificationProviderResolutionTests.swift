import Foundation
import Security
import Testing

@testable import Feeder

// MARK: - ClassificationEngine.buildProvider

/// The injected keychain-read closure keeps the test off the real keychain, so
/// no run pollutes the Security session or raises a prompt.
@Suite("ClassificationEngine.buildProvider")
struct ClassificationProviderResolutionTests {
  // MARK: - Per-test isolation

  /// Per-test isolated `UserDefaults`, so reads and writes of
  /// `ClassificationProviderKind.userDefaultsKey` never touch `.standard`, and a
  /// parallel test cannot flip this test's `.persist` selection between the
  /// persist and the `buildProvider` call.
  private let isolatedDefaults: IsolatedDefaults
  private var defaults: UserDefaults { isolatedDefaults.defaults }
  private let categories = [CategoryDefinition(label: "tech", description: "Technology news")]

  init() throws {
    isolatedDefaults = try IsolatedDefaults("ClassificationProviderResolution")
  }

  // MARK: - Apple FM path

  /// `.appleFM` is the default kind. Resolving it must never call the
  /// keychain-read closure.
  @Test
  func appleFMKindSkipsKeychainEntirely() {
    ClassificationProviderKind.persist(.appleFM, in: defaults)

    var readCallCount = 0
    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in
      readCallCount += 1
      return "should-not-be-read"
    }

    #expect(readCallCount == 0)
    #expect(provider.name == "Apple FM")
  }

  // MARK: - Cloud providers without a stored key

  @Test(arguments: [nil, ""] as [String?])
  func cloudKindWithoutKeyKeepsItsProviderAndNeedsKey(storedKey: String?) async {
    ClassificationProviderKind.persist(.vercel, in: defaults)
    var requestedKeys: [String] = []
    let provider = ClassificationEngine.buildProvider(defaults: defaults) { key in
      requestedKeys.append(key)
      return storedKey
    }

    // Compare with the constant, not `kind.keychainKey`: this test checks that mapping.
    #expect(requestedKeys == [KeychainHelper.vercelAPIKeychainKey])
    #expect(provider is VercelClassificationProvider)
    #expect(!(await provider.isAvailable))
    let error = await #expect(throws: (any Error).self) {
      try await provider.validate(categories: categories)
    }
    let failure = error as? any ClassificationFailure
    #expect(failure?.batchAbort == .needsKey)
    #expect(failure?.retryDisposition == .blocked)
  }

  // MARK: - Cloud providers with an unreadable key

  private static let failedReads: [KeychainError] = [
    .osStatus(errSecAuthFailed), .osStatus(errSecUserCanceled), .osStatus(errSecInteractionNotAllowed), .osStatus(-1),
    .encodingFailed,
  ]

  @Test(arguments: ClassificationProviderResolutionTests.failedReads)
  func cloudKindWithUnreadableKeyKeepsItsProviderAndBlocks(failure: KeychainError) async {
    let kind = ClassificationProviderKind.vercel
    ClassificationProviderKind.persist(kind, in: defaults)
    var requestedKeys: [String] = []
    let provider = ClassificationEngine.buildProvider(defaults: defaults) { (key: String) throws(KeychainError) -> String? in
      requestedKeys.append(key)
      throw failure
    }

    #expect(requestedKeys == [KeychainHelper.vercelAPIKeychainKey])
    #expect(provider is UnreadableKeyClassificationProvider)
    let realProvider = ClassificationEngine.buildProvider(defaults: defaults) { _ in "sk-test-not-real" }
    #expect(provider.name == kind.displayName)
    #expect(provider.name == realProvider.name)
    #expect(!(await provider.isAvailable))
    let validateError = await #expect(throws: UnreadableKeyFailure.self) {
      try await provider.validate(categories: categories)
    }
    let classifyError = await #expect(throws: UnreadableKeyFailure.self) {
      _ = try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
    for error in [validateError, classifyError] {
      #expect(error?.batchAbort == .keyUnreadable)
      #expect(error?.retryDisposition == .blocked)
      #expect(error?.isSkippable == false)
    }
  }

  // MARK: - Unknown stored provider

  /// A stored `openai` value names no provider. It resolves to the default
  /// provider, and the resolution reads no Keychain item.
  @Test
  func storedOpenAIProviderResolvesToAppleFMWithoutAKeychainRead() {
    defaults.set("openai", forKey: ClassificationProviderKind.userDefaultsKey)
    #expect(ClassificationProviderKind.current(in: defaults) == .appleFM)

    var requestedKeys: [String] = []
    let provider = ClassificationEngine.buildProvider(defaults: defaults) { key in
      requestedKeys.append(key)
      return "sk-test-not-real"
    }

    #expect(requestedKeys.isEmpty)
    #expect(provider is AppleFMClassificationProvider)
  }

  // MARK: - Vercel decision model resolution

  @Test(arguments: VercelDecisionModel.allCases)
  func buildProviderPassesStoredDecisionModelToVercelProvider(model: VercelDecisionModel) {
    ClassificationProviderKind.persist(.vercel, in: defaults)
    VercelDecisionModel.persist(model, in: defaults)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in "vercel-test-not-real" }

    #expect((provider as? VercelClassificationProvider)?.model == model)
  }

  @Test
  func buildProviderDefaultsToJEVWhenNoDecisionModelStored() {
    ClassificationProviderKind.persist(.vercel, in: defaults)
    #expect(defaults.string(forKey: VercelDecisionModel.userDefaultsKey) == nil)

    let provider = ClassificationEngine.buildProvider(defaults: defaults) { _ in "vercel-test-not-real" }

    #expect((provider as? VercelClassificationProvider)?.model == .jev)
  }
}
