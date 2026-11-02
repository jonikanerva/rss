import Foundation
import FoundationModels
import Testing

@testable import Feeder

nonisolated struct AppleFMFailureContract: Sendable, CustomTestStringConvertible {
  let failure: AppleFMClassificationError
  let batchAbort: ClassificationAbortReason?
  let retryDisposition: ClassificationRetry
  let isSkippable: Bool
  let publicLogLabel: String

  var testDescription: String { "\(failure)" }
}

/// A test must build error values only and never call the model.
@Suite("Apple Foundation Models error mapping")
struct AppleFMClassificationErrorTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_000_000)

  // MARK: - Cancellation and availability

  @Test(arguments: [true, false])
  func cancellationIsNotMapped(isModelAvailable: Bool) {
    #expect(AppleFMClassificationError(CancellationError(), isModelAvailable: isModelAvailable, now: Self.now) == nil)
  }

  nonisolated private static let errorsWhileUnavailable: [any Error] = [
    LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "rate limit")),
    LanguageModelError.guardrailViolation(.init(debugDescription: "guardrail")),
    URLError(.notConnectedToInternet),
  ]

  @Test(arguments: AppleFMClassificationErrorTests.errorsWhileUnavailable)
  func unavailableModelOutranksTheError(_ error: any Error) {
    #expect(AppleFMClassificationError(error, isModelAvailable: false, now: Self.now) == .modelUnavailable)
  }

  @Test
  func unknownErrorIsUnexpected() {
    let error: any Error = URLError(.timedOut)
    #expect(AppleFMClassificationError(error, isModelAvailable: true, now: Self.now) == .unexpected(detail: String(describing: error)))
  }

  // MARK: - Foundation Models errors

  @Test
  func languageModelErrorMapsByCause() {
    let mapped: [(LanguageModelError, AppleFMClassificationError)] = [
      (.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "context")), .contextSizeExceeded),
      (.guardrailViolation(.init(debugDescription: "guardrail")), .guardrailViolation),
      (.refusal(.init(explanation: "refusal", debugDescription: "refusal")), .refusal),
      (.unsupportedLanguageOrLocale(.init(languageCode: Locale.LanguageCode("fi"), debugDescription: "language")), .unsupportedLanguage),
    ]
    for (error, expected) in mapped {
      #expect(AppleFMClassificationError(error, isModelAvailable: true, now: Self.now) == expected)
    }
  }

  @Test
  func rateLimitResetDateBecomesABoundedRetryAfter() {
    let resets: [(Date?, TimeInterval?)] = [
      (nil, nil),
      (Self.now.addingTimeInterval(30), 30),
      (Self.now.addingTimeInterval(-30), 0),
      (Self.now.addingTimeInterval(7200), 3600),
    ]
    for (resetDate, retryAfter) in resets {
      let error = LanguageModelError.rateLimited(.init(resetDate: resetDate, debugDescription: "rate limit"))
      #expect(AppleFMClassificationError(error, isModelAvailable: true, now: Self.now) == .rateLimited(retryAfter: retryAfter))
    }
  }

  @Test
  func otherFrameworkErrorIsUnexpected() {
    let errors: [any Error] = [
      LanguageModelError.unsupportedCapability(.init(capability: .toolCalling, debugDescription: "capability")),
      LanguageModelError.unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "transcript")),
      LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "guide")),
      LanguageModelError.timeout(.init(debugDescription: "timeout")),
      SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "assets")),
      LanguageModelSession.Error.concurrentRequests,
      LanguageModelSession.Error.transcriptMutationWhileResponding,
      GeneratedContent.ParsingError(rawContent: "model output", debugDescription: "parsing"),
    ]
    for error in errors {
      #expect(AppleFMClassificationError(error, isModelAvailable: true, now: Self.now) == .unexpected(detail: String(describing: error)))
    }
  }

  // MARK: - Failure contract

  nonisolated private static let contracts: [AppleFMFailureContract] = [
    AppleFMFailureContract(
      failure: .modelUnavailable, batchAbort: .appleIntelligenceUnavailable, retryDisposition: .poll, isSkippable: false,
      publicLogLabel: "modelUnavailable"),
    AppleFMFailureContract(
      failure: .instructionsTooLarge, batchAbort: .inputTooLarge, retryDisposition: .blocked, isSkippable: false,
      publicLogLabel: "instructionsTooLarge"),
    AppleFMFailureContract(
      failure: .categoriesDeclined, batchAbort: .categoriesDeclined, retryDisposition: .blocked, isSkippable: false,
      publicLogLabel: "categoriesDeclined"),
    AppleFMFailureContract(
      failure: .rateLimited(retryAfter: nil), batchAbort: .rateLimited, retryDisposition: .transient(retryAfter: nil),
      isSkippable: false, publicLogLabel: "rateLimited"),
    AppleFMFailureContract(
      failure: .rateLimited(retryAfter: 30), batchAbort: .rateLimited, retryDisposition: .transient(retryAfter: 30),
      isSkippable: false, publicLogLabel: "rateLimited"),
    AppleFMFailureContract(
      failure: .contextSizeExceeded, batchAbort: nil, retryDisposition: .poll, isSkippable: false,
      publicLogLabel: "contextSizeExceeded"),
    AppleFMFailureContract(
      failure: .guardrailViolation, batchAbort: nil, retryDisposition: .poll, isSkippable: false,
      publicLogLabel: "guardrailViolation"),
    AppleFMFailureContract(
      failure: .refusal, batchAbort: nil, retryDisposition: .poll, isSkippable: false, publicLogLabel: "refusal"),
    AppleFMFailureContract(
      failure: .unsupportedLanguage, batchAbort: nil, retryDisposition: .poll, isSkippable: false,
      publicLogLabel: "unsupportedLanguage"),
    AppleFMFailureContract(
      failure: .unexpected(detail: "secret"), batchAbort: .providerUnavailable, retryDisposition: .transient(retryAfter: nil),
      isSkippable: true, publicLogLabel: "unexpected"),
  ]

  /// Read each value through `any ClassificationFailure`: only a protocol
  /// requirement dispatches to the label of the enum.
  @Test(arguments: AppleFMClassificationErrorTests.contracts)
  func failureKeepsItsContract(_ row: AppleFMFailureContract) {
    let failure: any ClassificationFailure = row.failure
    #expect(failure.batchAbort == row.batchAbort)
    #expect(failure.retryDisposition == row.retryDisposition)
    #expect(failure.isSkippable == row.isSkippable)
    #expect(failure.publicLogLabel == row.publicLogLabel)
  }

  @Test
  func unexpectedLabelHoldsNoDetail() {
    let failure: any ClassificationFailure = AppleFMClassificationError.unexpected(detail: "secret")
    #expect(!failure.publicLogLabel.contains("secret"))
  }

  @Test
  func defaultLabelIsTheTypeName() {
    let failure: any ClassificationFailure = VercelClassificationError.needsKey
    #expect(failure.publicLogLabel == "VercelClassificationError")
  }

  // MARK: - Reset delay

  @Test
  func resetDelayIsBoundedToOneHour() {
    let now = Self.now
    #expect(retryAfterDelay(until: now.addingTimeInterval(30), now: now) == 30)
    #expect(retryAfterDelay(until: now, now: now) == 0)
    #expect(retryAfterDelay(until: now.addingTimeInterval(-30), now: now) == 0)
    #expect(retryAfterDelay(until: now.addingTimeInterval(3600), now: now) == 3600)
    #expect(retryAfterDelay(until: now.addingTimeInterval(7200), now: now) == 3600)
  }

  @Test
  func httpDateRetryAfterSharesTheBounds() {
    let now = Date(timeIntervalSince1970: 3600)
    #expect(retryAfterDelay("Thu, 01 Jan 1970 00:00:00 GMT", now: now) == 0)
    #expect(retryAfterDelay("Thu, 01 Jan 1970 03:00:00 GMT", now: now) == 3600)
  }
}
