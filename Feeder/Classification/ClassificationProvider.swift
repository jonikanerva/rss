import Foundation
import FoundationModels
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "Classification")

// MARK: - Provider protocol

/// A classification backend that takes article text and returns structured classification.
/// Implementations must be Sendable for use in detached Tasks.
protocol ClassificationProvider: Sendable {
  nonisolated var name: String { get }
  var isAvailable: Bool { get async }

  /// Language codes this provider supports, or nil if it supports all languages.
  var supportedLanguageCodes: Set<String>? { get async }

  func classify(
    title: String,
    body: String,
    url: String,
    instructions: String,
    validLabels: Set<String>
  ) async throws -> ProviderClassificationResult
}

/// Raw output from a provider before confidence gating.
nonisolated struct ProviderClassificationResult: Sendable {
  let category: String
  let storyKey: String
  let confidence: Double
}

// MARK: - Apple Foundation Models provider

/// Classifies articles using the on-device Apple Foundation Model with constrained decoding.
/// Uses native token counting to maximize article content within the context window.
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
    instructions: String,
    validLabels: Set<String>
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

    let options = GenerationOptions(sampling: .greedy)
    let response = try await session.respond(
      to: prompt,
      generating: ArticleClassification.self,
      options: options
    )
    let classification = response.content

    return ProviderClassificationResult(
      category: classification.category,
      storyKey: classification.storyKey,
      confidence: classification.confidence
    )
  }
}

// MARK: - Token-aware body fitting

/// Fit as much article body as possible within the token budget.
/// On macOS 26.4+ uses native token counting with binary search refinement.
/// On earlier versions falls back to character-based estimation (~4 chars per token).
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

  // Full-range binary search over the entire body for correctness across all scripts
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

  @Guide(
    description:
      "A short stable kebab-case topic key for story grouping, e.g. 'apple-m5-macbook-pro' or 'openai-dod-contract'")
  var storyKey: String

  @Guide(description: "How confident you are in the classification, from 0.0 (guessing) to 1.0 (certain)")
  var confidence: Double
}
