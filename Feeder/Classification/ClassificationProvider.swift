import Foundation
import FoundationModels

// MARK: - Provider protocol

nonisolated protocol ClassificationProvider: Sendable {
  var name: String { get }
  var isAvailable: Bool { get async }
  /// Nil means that the provider supports all languages.
  var supportedLanguageCodes: Set<String>? { get async }

  /// Validate local configuration only. This must not send a network request.
  func validate(categories: [CategoryDefinition]) async throws
  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult
}

extension ClassificationProvider {
  nonisolated func validate(categories: [CategoryDefinition]) async throws {}
}

nonisolated enum ProviderClassificationResult: Sendable, Equatable {
  case generative(category: String, confidence: Double)
  case choice(category: String)
}

// MARK: - Failure disposition

nonisolated enum ClassificationAbortReason: Equatable, Sendable {
  case modelRejected
  case keyRejected
  case offline
  case providerUnavailable
  case needsKey
  case invalidCategories
  case inputTooLarge
  case invalidResponse
  case rateLimited

  var displayLabel: String {
    switch self {
    case .modelRejected: "Model rejected the request"
    case .keyRejected: "API key was rejected"
    case .offline: "Categorizing paused — offline"
    case .providerUnavailable: "Categorizing paused — provider unavailable"
    case .needsKey: "Add an API key to start categorizing"
    case .invalidCategories: "JEV needs unique category labels and at most 255 categories"
    case .inputTooLarge: "Category definitions are too large for JEV"
    case .invalidResponse: "JEV returned an invalid result. Retry to try again."
    case .rateLimited: "Categorizing paused — service limit reached"
    }
  }

  var symbolName: String {
    self == .offline ? "wifi.slash" : "exclamationmark.triangle"
  }
}

/// A non-nil abort must preserve the pending entry and stop the batch.
nonisolated protocol ClassificationFailure: Error {
  var batchAbort: ClassificationAbortReason? { get }
  var retryDisposition: ClassificationRetry { get }
}

extension ClassificationFailure {
  nonisolated var retryDisposition: ClassificationRetry { .poll }
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
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    let instructions = buildClassificationInstructions(from: categories)
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

    return .generative(
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
