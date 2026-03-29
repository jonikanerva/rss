import Foundation
import FoundationModels
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "Classification")

// MARK: - Provider protocol

/// A classification backend that takes article text and returns structured classification.
/// Implementations must be Sendable for use in detached Tasks.
protocol ClassificationProvider: Sendable {
  var name: String { get }
  var isAvailable: Bool { get async }

  func classify(
    title: String,
    body: String,
    instructions: String,
    validLabels: Set<String>
  ) async throws -> ProviderClassificationResult
}

/// Raw output from a provider before confidence gating.
nonisolated struct ProviderClassificationResult: Sendable {
  let categories: [String]
  let storyKey: String
  let confidence: Double
}

// MARK: - Apple Foundation Models provider

/// Classifies articles using the on-device Apple Foundation Model with constrained decoding.
nonisolated struct AppleFMClassificationProvider: ClassificationProvider {
  let name = "Apple FM"

  /// Conservative context budget: ~3800 tokens to leave room for output and schema overhead.
  private let maxContextChars = 3800 * 4

  var isAvailable: Bool {
    get async {
      let model = SystemLanguageModel.default
      if case .available = model.availability { return true }
      return false
    }
  }

  func classify(
    title: String,
    body: String,
    instructions: String,
    validLabels: Set<String>
  ) async throws -> ProviderClassificationResult {
    let model = SystemLanguageModel.default
    let session = LanguageModelSession(model: model, instructions: instructions)

    let promptPrefix = "title: \(title)\ncontent: "
    let usedChars = instructions.count + promptPrefix.count
    let maxBodyChars = max(500, maxContextChars - usedChars)
    let truncatedBody = String(body.prefix(maxBodyChars))
    let prompt = promptPrefix + truncatedBody
    let options = GenerationOptions(sampling: .greedy)
    let response = try await session.respond(
      to: prompt,
      generating: ArticleClassification.self,
      options: options
    )
    let classification = response.content

    return ProviderClassificationResult(
      categories: classification.categories,
      storyKey: classification.storyKey,
      confidence: classification.confidence
    )
  }
}

// MARK: - Apple FM generable output type

@Generable
struct ArticleClassification {
  @Guide(
    description:
      "The most specific matching category labels from the provided list. Assign the deepest matching subcategory, not its parent.",
    .count(1...4))
  var categories: [String]

  @Guide(
    description:
      "A short stable kebab-case topic key for story grouping, e.g. 'apple-m5-macbook-pro' or 'openai-dod-contract'")
  var storyKey: String

  @Guide(description: "How confident you are in the classification, from 0.0 (guessing) to 1.0 (certain)")
  var confidence: Double
}
