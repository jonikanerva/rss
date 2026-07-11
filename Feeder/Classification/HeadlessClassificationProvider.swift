import Foundation

// MARK: - Headless classification provider (seam 2)

/// No-op `ClassificationProvider` used only in headless mode (#141). It never
/// touches the network or the Keychain: it assigns every article the explicit
/// `uncategorizedLabel` fallback, so the `VISION.md` "every article gets exactly
/// one main category" invariant still holds without a real backend.
///
/// Wired at `ClassificationEngine` construction via `providerFactoryOverride`
/// (see `FeederApp`), so the production `buildProvider()` — and therefore the
/// OpenAI-key Keychain read it performs when `.openAI` is selected — is never
/// reached on an automated launch, even if a classification batch were to fire
/// on the seeded data. This closes the OpenAI credential seam at construction.
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
