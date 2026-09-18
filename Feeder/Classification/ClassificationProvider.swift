import Foundation
import FoundationModels

// MARK: - Provider protocol

/// A classification backend that takes article text and returns a structured
/// classification. Every implementation must be `Sendable`, for use in a
/// detached task.
///
/// Explicitly `nonisolated`: under default MainActor isolation the protocol
/// would be MainActor-isolated, and an `actor` cannot conform to a
/// global-actor-isolated protocol.
nonisolated protocol ClassificationProvider: Sendable {
  nonisolated var name: String { get }
  var isAvailable: Bool { get async }

  /// Language codes this provider supports, or nil if it supports all languages.
  var supportedLanguageCodes: Set<String>? { get async }

  func classify(
    title: String,
    body: String,
    url: String,
    instructions: String
  ) async throws -> ProviderClassificationResult
}

/// Raw output from a provider before confidence gating.
nonisolated struct ProviderClassificationResult: Sendable {
  let category: String
  let confidence: Double
}

// MARK: - Failure disposition

/// The user-facing cause of a classification batch abort. Payload-free by
/// design, so raw API text cannot reach the UI through this type; the detail
/// stays in the runner's `.private` log line, and the literals below are the
/// whole user-visible surface.
nonisolated enum ClassificationAbortReason: Equatable, Sendable {
  case modelRejected
  case keyRejected
  case offline
  case providerUnavailable

  /// Fixed banner copy, as a fragment with no trailing period, like the other
  /// status labels. A test locks the literals.
  var displayLabel: String {
    switch self {
    case .modelRejected: "Model rejected the request"
    case .keyRejected: "API key was rejected"
    case .offline: "Categorizing paused — offline"
    case .providerUnavailable: "Categorizing paused — provider unavailable"
    }
  }

  var symbolName: String {
    switch self {
    case .offline: "wifi.slash"
    case .modelRejected, .keyRejected, .providerUnavailable: "exclamationmark.triangle"
    }
  }
}

/// Contract for a provider error that carries a batch-level disposition.
///
/// With a non-nil `batchAbort` the runner persists nothing for the failing
/// entry, ends the drain, and reports a terminal snapshot owning the outcome,
/// so the entry and the remainder stay unclassified for the next poll. This is
/// what keeps a user-chosen model safe: a deterministic provider failure must
/// never mass-persist the fallback category, and a full reclassify must stay
/// recoverable.
///
/// A nil `batchAbort`, and any error that does not conform, keeps the per-entry
/// fallback: the entry persists as uncategorized and the drain continues.
nonisolated protocol ClassificationFailure: Error {
  var batchAbort: ClassificationAbortReason? { get }
}

// MARK: - Apple Foundation Models provider

/// Classifies articles with the on-device Apple Foundation Model and
/// constrained decoding, using native token counting to fit as much article
/// content as the context window allows.
nonisolated struct AppleFMClassificationProvider: ClassificationProvider {
  let name = "Apple FM"

  /// Tokens reserved for output schema overhead and generated JSON.
  private let outputTokenReserve = 200

  var isAvailable: Bool {
    get async {
      let model = SystemLanguageModel.default
      if case .available = model.availability { return true }
      return false
    }
  }

  var supportedLanguageCodes: Set<String>? {
    get async {
      let model = SystemLanguageModel.default
      return Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })
    }
  }

  func classify(
    title: String,
    body: String,
    url: String,
    instructions: String
  ) async throws -> ProviderClassificationResult {
    let model = SystemLanguageModel.default
    let session = LanguageModelSession(model: model, instructions: instructions)

    let contextSize: Int
    if #available(macOS 26.4, *) {
      contextSize = model.contextSize
    } else {
      contextSize = 4096
    }
    let maxInputTokens = contextSize - outputTokenReserve
    let promptPrefix = "title: \(title)\nurl: \(url)\ncontent: "
    let truncatedBody = try await fitBody(
      body: body,
      prefix: promptPrefix,
      instructions: instructions,
      maxInputTokens: maxInputTokens,
      model: model
    )
    let prompt = promptPrefix + truncatedBody

    let options = GenerationOptions(samplingMode: .greedy)
    let response = try await session.respond(
      to: prompt,
      generating: ArticleClassification.self,
      options: options
    )
    let classification = response.content

    return ProviderClassificationResult(
      category: classification.category,
      confidence: classification.confidence
    )
  }
}

// MARK: - Token-aware body fitting

/// Fit as much article body as the token budget allows: native token counting
/// with a binary search where it is available, and a character-based estimate
/// otherwise.
nonisolated private func fitBody(
  body: String,
  prefix: String,
  instructions: String,
  maxInputTokens: Int,
  model: SystemLanguageModel
) async throws -> String {
  guard #available(macOS 26.4, *) else {
    return fitBodyWithCharEstimate(
      body: body, prefix: prefix, instructions: instructions,
      maxInputTokens: maxInputTokens
    )
  }
  return try await fitBodyWithTokenCounting(
    body: body, prefix: prefix, instructions: instructions,
    maxInputTokens: maxInputTokens, model: model
  )
}

@available(macOS 26.4, *)
nonisolated private func fitBodyWithTokenCounting(
  body: String,
  prefix: String,
  instructions: String,
  maxInputTokens: Int,
  model: SystemLanguageModel
) async throws -> String {
  let fullText = instructions + prefix + body
  let fullTokens = try await model.tokenCount(for: fullText)
  if fullTokens <= maxInputTokens {
    return body
  }

  // Search the full range, so the result is correct in every script.
  var low = 0
  var high = body.count
  var bestEnd = 0

  while low <= high {
    let mid = (low + high) / 2
    let candidate = instructions + prefix + String(body.prefix(mid))
    let tokens = try await model.tokenCount(for: candidate)
    if tokens <= maxInputTokens {
      bestEnd = mid
      low = mid + 1
    } else {
      high = mid - 1
    }
  }

  return String(body.prefix(bestEnd))
}

nonisolated private func fitBodyWithCharEstimate(
  body: String,
  prefix: String,
  instructions: String,
  maxInputTokens: Int
) -> String {
  let maxChars = maxInputTokens * 4
  let usedChars = instructions.count + prefix.count
  let maxBodyChars = max(500, maxChars - usedChars)
  return String(body.prefix(maxBodyChars))
}

// MARK: - Apple FM generable output type

@Generable
struct ArticleClassification {
  @Guide(
    description:
      "The single best matching category label from the provided list.")
  var category: String

  @Guide(description: "How confident you are in the classification, from 0.0 (guessing) to 1.0 (certain)")
  var confidence: Double
}
