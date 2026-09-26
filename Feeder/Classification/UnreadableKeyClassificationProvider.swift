import Foundation

/// Stands in for the selected cloud provider when the Keychain read of its API
/// key fails. Must send no request and must never select another provider.
nonisolated struct UnreadableKeyClassificationProvider: ClassificationProvider {
  let name: String

  var isAvailable: Bool { get async { false } }
  var supportedLanguageCodes: Set<String>? { get async { nil } }

  func validate(categories: [CategoryDefinition]) async throws {
    throw UnreadableKeyFailure()
  }

  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    throw UnreadableKeyFailure()
  }
}

nonisolated struct UnreadableKeyFailure: ClassificationFailure {
  var batchAbort: ClassificationAbortReason? { .keyUnreadable }
  var retryDisposition: ClassificationRetry { .blocked }
}
