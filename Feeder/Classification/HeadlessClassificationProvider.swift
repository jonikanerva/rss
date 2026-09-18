import Foundation

// MARK: - Headless classification provider (seam 2)

/// No-op `ClassificationProvider` for headless mode. It touches neither the
/// network nor the Keychain, and assigns every article the explicit fallback
/// label, so the "exactly one main category" invariant
/// (`VISION.md → Core Principles`) holds without a backend.
///
/// It is wired at `ClassificationEngine` construction, so an automated launch
/// never reaches `buildProvider()` or the Keychain read it performs, even if a
/// batch fires on the seeded data.
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
    instructions: String
  ) async throws -> ProviderClassificationResult {
    // Confidence 0 drives `applyConfidenceGate` to the fallback label — no
    // guess, no network, no Keychain.
    ProviderClassificationResult(category: uncategorizedLabel, confidence: 0)
  }
}
