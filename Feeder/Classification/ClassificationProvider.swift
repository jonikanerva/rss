import Foundation
import FoundationModels

// MARK: - Provider protocol

nonisolated protocol ClassificationProvider: Sendable {
  var name: String { get }
  var isAvailable: Bool { get async }
  /// The banner reason when `isAvailable` is false.
  var unavailableAbort: ClassificationAbortReason { get }
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
  nonisolated var unavailableAbort: ClassificationAbortReason { .providerUnavailable }
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
  case appleIntelligenceUnavailable
  case needsKey
  case keyUnreadable
  case invalidCategories
  case inputTooLarge
  case categoriesDeclined
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
    case .appleIntelligenceUnavailable: "Apple Intelligence is not available — check System Settings"
    case .needsKey: "Add an API key to start categorizing"
    case .keyUnreadable: "Could not read the API key from Keychain"
    case .invalidCategories: "The selected model needs unique category labels and at most 255 categories"
    case .inputTooLarge: "Category definitions are too large for the selected model"
    case .categoriesDeclined: "Apple Intelligence declined the category definitions"
    case .invalidResponse: "The selected model returned an invalid result"
    case .rateLimited: "Categorizing paused — service limit reached"
    case .quotaExhausted:
      // No `default:`: a new provider kind must choose its own billing copy.
      switch provider {
      case .vercel: "Vercel quota used up — check billing at Vercel"
      case .appleFM, nil: "Quota used up — check billing at the provider"
      }
    }
  }

  /// A timeout on a working network is not an offline Mac, so the banner names
  /// the provider instead. `nil` means a failure without a `URLError` code.
  static func transportFailure(_ code: URLError.Code?) -> ClassificationAbortReason {
    code == .timedOut ? .providerUnavailable : .offline
  }

  var symbolName: String {
    self == .offline ? "wifi.slash" : "exclamationmark.triangle"
  }

  /// A blocked failure must use a reason that offers Settings, and a transient
  /// failure a reason that does not (`STACK.md → Cloud classification`).
  var offersSettings: Bool {
    switch self {
    case .keyRejected, .modelRejected, .needsKey, .keyUnreadable, .invalidCategories, .inputTooLarge, .categoriesDeclined,
      .invalidResponse, .quotaExhausted:
      true
    case .offline, .providerUnavailable, .appleIntelligenceUnavailable, .rateLimited: false
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
/// content as the context window allows. Build one instance per drain: the
/// guardrail streak counts the failures of one drain only.
nonisolated struct AppleFMClassificationProvider: ClassificationProvider {
  /// The token count of the instructions with an empty prompt, and the context
  /// size of the model.
  nonisolated struct InstructionMeasure: Sendable, Equatable {
    let tokenCount: Int
    let contextSize: Int
  }

  /// Consecutive guardrail failures that stop the drain
  /// (`STACK.md → Cloud classification`).
  static let declinedCategoriesStreak = 3
  /// Tokens reserved for output schema overhead and generated JSON.
  private static let outputTokenReserve = 200

  let name = "Apple FM"
  let unavailableAbort = ClassificationAbortReason.appleIntelligenceUnavailable
  private let availability: @Sendable () -> SystemLanguageModel.Availability
  private let languageCodes: @Sendable () -> Set<String>
  private let measureInstructions: @Sendable (String) async throws -> InstructionMeasure
  private let generate: @Sendable (String, String, String, [CategoryDefinition]) async throws -> ProviderClassificationResult
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date
  private let guardrailStreak = GuardrailStreak()

  init(
    availability: @escaping @Sendable () -> SystemLanguageModel.Availability = { SystemLanguageModel.default.availability },
    languageCodes: @escaping @Sendable () -> Set<String> = {
      Set(SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier })
    },
    measureInstructions: @escaping @Sendable (String) async throws -> InstructionMeasure = Self.measureWithSystemModel,
    generate: @escaping @Sendable (String, String, String, [CategoryDefinition]) async throws -> ProviderClassificationResult =
      Self.generateWithSystemModel,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.availability = availability
    self.languageCodes = languageCodes
    self.measureInstructions = measureInstructions
    self.generate = generate
    self.sleep = sleep
    self.now = now
  }

  var isAvailable: Bool {
    get async { Self.abortReason(for: availability()) == nil }
  }

  var supportedLanguageCodes: Set<String>? {
    get async { languageCodes() }
  }

  /// Nil means that the model is available. Every unavailability cause gets the
  /// same banner reason.
  static func abortReason(for availability: SystemLanguageModel.Availability) -> ClassificationAbortReason? {
    switch availability {
    case .available: nil
    case .unavailable(.appleIntelligenceNotEnabled), .unavailable(.deviceNotEligible), .unavailable(.modelNotReady):
      .appleIntelligenceUnavailable
    @unknown default: .appleIntelligenceUnavailable
    }
  }

  /// The model counts the context size and the tokens only while it is
  /// available, so an unavailable model skips the check and the availability
  /// gate of the runner reports it.
  func validate(categories: [CategoryDefinition]) async throws {
    await guardrailStreak.reset()
    guard await isAvailable else { return }
    let instructions = buildClassificationInstructions(from: categories) + Self.promptPrefix(title: "", url: "")
    let measure: InstructionMeasure
    do {
      measure = try await measureInstructions(instructions)
    } catch {
      throw try await mapped(error)
    }
    guard Self.instructionsFit(measure) else { throw AppleFMClassificationError.instructionsTooLarge }
  }

  static func instructionsFit(_ measure: InstructionMeasure) -> Bool {
    measure.tokenCount <= measure.contextSize - outputTokenReserve
  }

  /// A rate limit gets the request retry of a cloud rate limit
  /// (`STACK.md → Cloud classification`). Cancellation throws
  /// `CancellationError`, also during a retry wait.
  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    var attempt = 1
    while true {
      try Task.checkCancellation()
      let failure: AppleFMClassificationError
      do {
        let result = try await generate(title, body, url, categories)
        await guardrailStreak.reset()
        return result
      } catch {
        failure = try await mapped(error)
      }
      if failure == .guardrailViolation {
        let streak = await guardrailStreak.recordViolation()
        throw streak >= Self.declinedCategoriesStreak ? AppleFMClassificationError.categoriesDeclined : failure
      }
      await guardrailStreak.reset()
      guard case .rateLimited(let retryAfter) = failure,
        let wait = CloudRequestRetry.delay(afterAttempt: attempt, retryAfter: retryAfter)
      else { throw failure }
      try await sleep(wait)
      attempt += 1
    }
  }

  /// Rethrows a cancellation unchanged.
  private func mapped(_ error: any Error) async throws -> AppleFMClassificationError {
    if Task.isCancelled { throw CancellationError() }
    guard let failure = AppleFMClassificationError(error, isModelAvailable: await isAvailable, now: now()) else { throw error }
    return failure
  }

  private static func promptPrefix(title: String, url: String) -> String {
    "title: \(title)\nurl: \(url)\ncontent: "
  }

  private static func contextSize(of model: SystemLanguageModel) -> Int {
    if #available(macOS 26.4, *) { model.contextSize } else { 4096 }
  }

  @Sendable
  private static func measureWithSystemModel(_ instructions: String) async throws -> InstructionMeasure {
    let model = SystemLanguageModel.default
    let contextSize = contextSize(of: model)
    guard #available(macOS 26.4, *) else {
      return InstructionMeasure(tokenCount: charEstimatedTokens(instructions.count), contextSize: contextSize)
    }
    return InstructionMeasure(tokenCount: try await model.tokenCount(for: instructions), contextSize: contextSize)
  }

  @Sendable
  private static func generateWithSystemModel(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    let instructions = buildClassificationInstructions(from: categories)
    let model = SystemLanguageModel.default
    let session = LanguageModelSession(model: model, instructions: instructions)

    let maxInputTokens = contextSize(of: model) - outputTokenReserve
    let promptPrefix = promptPrefix(title: title, url: url)
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

/// Consecutive guardrail failures in one drain. Any other request outcome
/// resets the count.
private actor GuardrailStreak {
  private var count = 0

  func reset() { count = 0 }

  func recordViolation() -> Int {
    count += 1
    return count
  }
}

// MARK: - Apple Foundation Models failures

nonisolated enum AppleFMClassificationError: Error, ClassificationFailure, Equatable {
  case modelUnavailable
  case instructionsTooLarge
  case categoriesDeclined
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
    case .modelUnavailable: .appleIntelligenceUnavailable
    case .unexpected: .providerUnavailable
    case .instructionsTooLarge: .inputTooLarge
    case .categoriesDeclined: .categoriesDeclined
    case .rateLimited: .rateLimited
    case .contextSizeExceeded, .guardrailViolation, .refusal, .unsupportedLanguage: nil
    }
  }

  var retryDisposition: ClassificationRetry {
    switch self {
    case .rateLimited(let retryAfter): .transient(retryAfter: retryAfter)
    case .unexpected: .transient(retryAfter: nil)
    case .instructionsTooLarge, .categoriesDeclined: .blocked
    case .modelUnavailable, .contextSizeExceeded, .guardrailViolation, .refusal, .unsupportedLanguage: .poll
    }
  }

  var publicLogLabel: String {
    switch self {
    case .modelUnavailable: "modelUnavailable"
    case .instructionsTooLarge: "instructionsTooLarge"
    case .categoriesDeclined: "categoriesDeclined"
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
  let maxChars = maxInputTokens * charsPerEstimatedToken
  let usedChars = instructions.count + prefix.count
  let maxBodyChars = max(500, maxChars - usedChars)
  return String(body.prefix(maxBodyChars))
}

nonisolated private let charsPerEstimatedToken = 4

nonisolated private func charEstimatedTokens(_ characterCount: Int) -> Int {
  (characterCount + charsPerEstimatedToken - 1) / charsPerEstimatedToken
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
