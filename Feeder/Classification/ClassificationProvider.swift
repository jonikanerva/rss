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

/// Payload-free on purpose: raw API text must not reach the UI through this
/// type. The failure detail goes to a `.private` log line.
nonisolated enum ClassificationAbortReason: Equatable, Sendable {
  case modelRejected
  case keyRejected
  case offline
  case providerUnavailable
  case needsKey
  case keyUnreadable
  case invalidCategories
  case inputTooLarge
  case invalidResponse
  case rateLimited
  case quotaExhausted

  /// Fixed banner copy: a fragment with no trailing period, like the other
  /// status labels. A test locks the literals.
  func displayLabel(reportedBy provider: ClassificationProviderKind?) -> String {
    switch self {
    case .modelRejected: "Model rejected the request"
    case .keyRejected: "API key was rejected"
    case .offline: "Categorizing paused — offline"
    case .providerUnavailable: "Categorizing paused — provider unavailable"
    case .needsKey: "Add an API key to start categorizing"
    case .keyUnreadable: "Could not read the API key from Keychain"
    case .invalidCategories: "JEV needs unique category labels and at most 255 categories"
    case .inputTooLarge: "Category definitions are too large for JEV"
    case .invalidResponse: "JEV returned an invalid result"
    case .rateLimited: "Categorizing paused — service limit reached"
    case .quotaExhausted:
      // No `default:`: a new provider kind must choose its own billing copy.
      switch provider {
      case .vercel: "Vercel quota used up — check billing at Vercel"
      case .openAI, .appleFM, nil: "OpenAI quota used up — check billing at OpenAI"
      }
    }
  }

  var symbolName: String {
    self == .offline ? "wifi.slash" : "exclamationmark.triangle"
  }

  /// A blocked failure must use a reason that offers Settings, and a transient
  /// failure a reason that does not (`STACK.md → Cloud classification`).
  var offersSettings: Bool {
    switch self {
    case .keyRejected, .modelRejected, .needsKey, .keyUnreadable, .invalidCategories, .inputTooLarge, .invalidResponse, .quotaExhausted:
      true
    case .offline, .providerUnavailable, .rateLimited: false
    }
  }
}

/// A non-nil abort must preserve the pending entry. It stops the batch unless
/// `isSkippable` is true. A nil abort, or an error that does not conform,
/// persists the entry as uncategorized and continues the drain.
nonisolated protocol ClassificationFailure: Error {
  var batchAbort: ClassificationAbortReason? { get }
  /// `CloudSession.sendWithRetry` reads this too: only a `.transient` failure
  /// gets a request retry.
  var retryDisposition: ClassificationRetry { get }
  /// Must hold no user data: the runner logs it with public privacy.
  var publicLogLabel: String { get }
}

extension ClassificationFailure {
  nonisolated var retryDisposition: ClassificationRetry { .poll }
  nonisolated var publicLogLabel: String { String(describing: Self.self) }
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
    do {
      return try await generate(title: title, body: body, url: url, categories: categories)
    } catch {
      guard let failure = AppleFMClassificationError(error, isModelAvailable: await isAvailable, now: Date()) else { throw error }
      throw failure
    }
  }

  private func generate(
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

// MARK: - Apple Foundation Models failures

nonisolated enum AppleFMClassificationError: Error, ClassificationFailure, Equatable {
  case modelUnavailable
  case rateLimited(retryAfter: TimeInterval?)
  case contextSizeExceeded
  case guardrailViolation
  case refusal
  case unsupportedLanguage
  /// The detail can hold model output: log it only with private privacy.
  case unexpected(detail: String)

  /// Nil means a cancellation: the caller must rethrow `error` unchanged. When
  /// `isModelAvailable` is false, every other error maps to `.modelUnavailable`.
  init?(_ error: any Error, isModelAvailable: Bool, now: Date) {
    if error is CancellationError { return nil }
    if !isModelAvailable {
      self = .modelUnavailable
    } else if #available(macOS 27.0, *), let failure = Self.macOS27Failure(error, now: now) {
      self = failure
    } else if let error = error as? LanguageModelSession.GenerationError {
      self = Self.failure(error)
    } else {
      self = .unexpected(detail: String(describing: error))
    }
  }

  var batchAbort: ClassificationAbortReason? {
    switch self {
    case .modelUnavailable, .unexpected: .providerUnavailable
    case .rateLimited: .rateLimited
    case .contextSizeExceeded, .guardrailViolation, .refusal, .unsupportedLanguage: nil
    }
  }

  var retryDisposition: ClassificationRetry {
    switch self {
    case .rateLimited(let retryAfter): .transient(retryAfter: retryAfter)
    case .unexpected: .transient(retryAfter: nil)
    case .modelUnavailable, .contextSizeExceeded, .guardrailViolation, .refusal, .unsupportedLanguage: .poll
    }
  }

  var publicLogLabel: String {
    switch self {
    case .modelUnavailable: "modelUnavailable"
    case .rateLimited: "rateLimited"
    case .contextSizeExceeded: "contextSizeExceeded"
    case .guardrailViolation: "guardrailViolation"
    case .refusal: "refusal"
    case .unsupportedLanguage: "unsupportedLanguage"
    case .unexpected: "unexpected"
    }
  }

  // Each Foundation Models switch in this type lists every case and ends with
  // `@unknown default`, so a new SDK case gives a build warning.
  @available(macOS 27.0, *)
  private static func macOS27Failure(_ error: any Error, now: Date) -> Self? {
    let unexpected = Self.unexpected(detail: String(describing: error))
    if let error = error as? LanguageModelError {
      switch error {
      case .contextSizeExceeded: return .contextSizeExceeded
      case .rateLimited(let limit): return .rateLimited(retryAfter: limit.resetDate.map { retryAfterDelay(until: $0, now: now) })
      case .guardrailViolation: return .guardrailViolation
      case .refusal: return .refusal
      case .unsupportedLanguageOrLocale: return .unsupportedLanguage
      case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide, .timeout: return unexpected
      @unknown default: return unexpected
      }
    }
    if let error = error as? SystemLanguageModel.Error {
      switch error {
      case .assetsUnavailable: return unexpected
      @unknown default: return unexpected
      }
    }
    if let error = error as? LanguageModelSession.Error {
      switch error {
      case .concurrentRequests, .transcriptMutationWhileResponding: return unexpected
      @unknown default: return unexpected
      }
    }
    return error is GeneratedContent.ParsingError ? unexpected : nil
  }

  private static func failure(_ error: LanguageModelSession.GenerationError) -> Self {
    switch error {
    case .exceededContextWindowSize: .contextSizeExceeded
    case .guardrailViolation: .guardrailViolation
    case .refusal: .refusal
    case .unsupportedLanguageOrLocale: .unsupportedLanguage
    case .rateLimited: .rateLimited(retryAfter: nil)
    case .assetsUnavailable, .decodingFailure, .concurrentRequests, .unsupportedGuide: .unexpected(detail: String(describing: error))
    @unknown default: .unexpected(detail: String(describing: error))
    }
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
