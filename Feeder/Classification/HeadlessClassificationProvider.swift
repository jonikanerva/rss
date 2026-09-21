import Foundation

// MARK: - Headless classification provider (seam 2)

/// Must perform no network or Keychain access, including when used with seeded data.
nonisolated struct HeadlessClassificationProvider: ClassificationProvider {
  let name = "Headless (no-op)"

  var isAvailable: Bool { get async { true } }

  /// Supports every language so the engine's language gate never routes around
  /// this provider toward a real backend.
  var supportedLanguageCodes: Set<String>? { get async { nil } }

  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    ProviderClassificationResult.generative(category: uncategorizedLabel, confidence: 0)
  }
}
