import Foundation
import Testing

@testable import Feeder

// MARK: - OpenAI request wire shape

/// Regression pin for the field-tested gpt-5.6-luna failure: the model
/// rejects `temperature: 0` with a deterministic 400 ("Only the default (1)
/// value is supported"), which — before the abort path — would have burned
/// the corpus to Uncategorized. The maximally compatible request shape
/// sends NO sampling parameters and lets each model's default apply, so
/// this test fails if anyone reintroduces a `temperature` key.
@Suite("OpenAI request shape")
struct OpenAIRequestShapeTests {
  @Test
  func encodedRequestBodyOmitsTemperature() throws {
    let body = try OpenAIClassificationProvider.encodeRequestBody(
      model: "gpt-5.6-luna",
      instructions: "Classify the article.",
      userMessage: "title: Example\ncontent: body"
    )

    let object = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["temperature"] == nil, "Request must not send a temperature key")

    // The load-bearing keys are still present.
    #expect(object["model"] as? String == "gpt-5.6-luna")
    #expect(object["messages"] is [[String: Any]])
    #expect(object["response_format"] is [String: Any])
  }
}
