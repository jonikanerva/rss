import Foundation
import Testing

@testable import Feeder

// MARK: - Fixture helpers

/// Memberwise construction shorthand for catalog fixtures — `created` from
/// unix seconds mirrors the wire representation.
private func model(_ id: String, createdUnixSeconds: Double = 0) -> OpenAIModel {
  OpenAIModel(id: id, created: Date(timeIntervalSince1970: createdUnixSeconds))
}

// MARK: - Wire decoding

/// Pins the documented `GET /v1/models` wire shape: `{"object": "list",
/// "data": [{id, created, owned_by, ...}]}` with `created` in unix seconds,
/// decoded to a `Date` instant at the wire boundary. Extra fields — present
/// today and free to grow — must be tolerated.
@Suite("OpenAIModelsClient.decodeModelList")
struct OpenAIModelListDecodingTests {
  @Test
  func decodesDocumentedWireShapeWithExtraFields() throws {
    let wireData = Data(
      """
      {
        "object": "list",
        "data": [
          {"id": "gpt-5.6-luna", "object": "model", "created": 1750000000, "owned_by": "system"},
          {"id": "whisper-1", "object": "model", "created": 1677532384, "owned_by": "openai-internal", "future_field": true},
          {"id": "gpt-5.4-nano", "object": "model", "created": 1740000000, "owned_by": "system"}
        ]
      }
      """.utf8)

    let models = try OpenAIModelsClient.decodeModelList(wireData)

    #expect(models.map(\.id) == ["gpt-5.6-luna", "whisper-1", "gpt-5.4-nano"])
    #expect(models.first?.created == Date(timeIntervalSince1970: 1_750_000_000))
    #expect(models.last?.created == Date(timeIntervalSince1970: 1_740_000_000))
  }

  @Test
  func malformedPayloadThrowsDecodingFailed() {
    let malformed = Data("not json at all".utf8)
    #expect(throws: OpenAIModelsError.decodingFailed) {
      try OpenAIModelsClient.decodeModelList(malformed)
    }
  }

  @Test
  func emptyDataArrayDecodesToEmptyList() throws {
    let emptyList = Data(#"{"object": "list", "data": []}"#.utf8)
    let models = try OpenAIModelsClient.decodeModelList(emptyList)
    #expect(models.isEmpty)
  }
}

// MARK: - Catalog filter (fail-open proof)

/// The denylist is cosmetic UX hygiene: known non-chat families are hidden,
/// but every unknown/future id PASSES — the issue's "new models usable
/// without rebuilding" requirement. The safety mechanism for a bad pick is
/// the `ClassificationFailure` abort path, not this filter.
@Suite("filterClassificationModels")
struct ClassificationModelFilterTests {
  @Test(arguments: [
    "text-embedding-3-small",
    "whisper-1",
    "tts-1",
    "dall-e-3",
    "omni-moderation-latest",
    "gpt-4o-realtime-preview",
    "gpt-4o-audio-preview",
    "gpt-image-1",
    "gpt-4o-transcribe",
    "gpt-4o-search-preview",
    "davinci-002",
    "babbage-002",
  ])
  func excludesKnownNonClassificationFamilies(deniedID: String) {
    let kept = filterClassificationModels([model(deniedID)])
    #expect(kept.isEmpty, "\(deniedID) must be filtered out")
  }

  @Test(arguments: ["gpt-7-frontier", "gpt-5.6-luna", "gpt-5.4-nano"])
  func keepsChatModelsAndUnknownFutureIDs(keptID: String) {
    let kept = filterClassificationModels([model(keptID)])
    #expect(kept.map(\.id) == [keptID], "\(keptID) must pass the filter (fail-open)")
  }

  @Test
  func matchesDenylistCaseInsensitively() {
    let kept = filterClassificationModels([model("GPT-4O-AUDIO-PREVIEW"), model("Whisper-1")])
    #expect(kept.isEmpty)
  }
}

// MARK: - Newest-first sort

@Suite("sortModelsNewestFirst")
struct ModelSortTests {
  /// Sorts on the `Date` instant, descending — the settings mirror of the
  /// product's newest-first principle.
  @Test
  func sortsByCreatedDescending() {
    let unsorted = [
      model("oldest", createdUnixSeconds: 1_000),
      model("newest", createdUnixSeconds: 3_000),
      model("middle", createdUnixSeconds: 2_000),
    ]
    let sorted = sortModelsNewestFirst(unsorted)
    #expect(sorted.map(\.id) == ["newest", "middle", "oldest"])
  }
}

// MARK: - State reducer

@Suite("resolveModelListState")
struct ModelListStateReducerTests {
  /// Success with usable models → `.loaded`, filtered and newest first.
  @Test
  func successWithUsableModelsIsLoadedNewestFirst() {
    let outcome: Result<[OpenAIModel], OpenAIModelsError> = .success([
      model("gpt-5.4-nano", createdUnixSeconds: 1_000),
      model("whisper-1", createdUnixSeconds: 9_000),
      model("gpt-5.6-luna", createdUnixSeconds: 2_000),
    ])
    #expect(
      resolveModelListState(outcome: outcome) == .loaded(["gpt-5.6-luna", "gpt-5.4-nano"])
    )
  }

  /// Success where nothing survives the filter (or the list is empty) →
  /// `.empty` — "no compatible models", not a blank picker.
  @Test
  func successWithNoUsableModelsIsEmpty() {
    #expect(resolveModelListState(outcome: .success([])) == .empty)
    #expect(resolveModelListState(outcome: .success([model("whisper-1")])) == .empty)
  }

  /// A rejected key reads differently from a network problem — the user's
  /// next action (fix the key vs wait for connectivity) depends on it.
  @Test
  func unauthorizedAndNetworkFailuresHaveDistinctReasons() {
    let unauthorized = resolveModelListState(outcome: .failure(.unauthorized))
    let network = resolveModelListState(outcome: .failure(.network))

    #expect(unauthorized == .failed(reason: "API key was rejected."))
    guard case .failed(let networkReason) = network else {
      Issue.record("Expected .failed for a network error, got \(String(describing: network))")
      return
    }
    #expect(networkReason != "API key was rejected.")
  }

  @Test
  func httpAndDecodeFailuresResolveToFailed() {
    guard case .failed(let httpReason) = resolveModelListState(outcome: .failure(.httpStatus(503)))
    else {
      Issue.record("Expected .failed for an HTTP error")
      return
    }
    #expect(httpReason.contains("503"))

    guard case .failed = resolveModelListState(outcome: .failure(.decodingFailed)) else {
      Issue.record("Expected .failed for a decode error")
      return
    }
  }
}

// MARK: - Picker options invariant

@Suite("pickerOptions")
struct PickerOptionsTests {
  /// INVARIANT: options always contain the persisted selection and the app
  /// default, deduped, in every state — a `Picker` whose selection is not
  /// among its tags renders blank. Covers the selection-absent-from-fetched-
  /// list case (a previously picked model the API no longer returns).
  @Test
  func selectionAndDefaultArePresentAndDedupedInEveryState() {
    let states: [ModelListState] = [
      .needsKey,
      .loading,
      .empty,
      .failed(reason: "API key was rejected."),
      .loaded(["gpt-a", "gpt-b"]),
      .loaded([]),
      .loaded(["custom-pick"]),
      .loaded(["custom-pick", "gpt-5.6-luna"]),
    ]
    for state in states {
      let options = pickerOptions(
        for: state, selection: "custom-pick", defaultModel: "gpt-5.6-luna"
      )
      #expect(options.contains("custom-pick"), "selection missing in \(String(describing: state))")
      #expect(options.contains("gpt-5.6-luna"), "default missing in \(String(describing: state))")
      #expect(Set(options).count == options.count, "duplicates in \(String(describing: state))")
    }
  }

  /// Loaded options preserve the fetched (newest-first) order, with the
  /// floor entries appended only when missing.
  @Test
  func loadedOptionsPreserveFetchedOrder() {
    let options = pickerOptions(
      for: .loaded(["gpt-new", "gpt-old"]), selection: "gpt-old", defaultModel: "gpt-default"
    )
    #expect(options == ["gpt-new", "gpt-old", "gpt-default"])
  }

  /// Non-loaded states offer exactly the floor: selection then default.
  @Test
  func nonLoadedStatesOfferTheFloor() {
    let options = pickerOptions(for: .loading, selection: "custom-pick", defaultModel: "gpt-5.6-luna")
    #expect(options == ["custom-pick", "gpt-5.6-luna"])

    let collapsed = pickerOptions(
      for: .needsKey, selection: "gpt-5.6-luna", defaultModel: "gpt-5.6-luna"
    )
    #expect(collapsed == ["gpt-5.6-luna"])
  }
}

// MARK: - Resolving never persists

/// Proof that the read path cannot pin the user: running the reducer and the
/// options builder over every outcome leaves the `openai_model` key unset.
/// Only an explicit user pick (the view's single `persist` call site) writes
/// it — a programmatic write here would silently freeze every unset user at
/// the then-current default.
@Suite("Model resolution never writes")
struct ModelResolutionNeverWritesTests {
  @Test
  func resolvingStatesAndOptionsLeavesModelKeyUnset() {
    let id = "FeederTests.ModelResolutionNeverWrites.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: id) else {
      fatalError("Failed to construct test-isolated UserDefaults suite \(id)")
    }
    #expect(defaults.string(forKey: OpenAIModelSetting.userDefaultsKey) == nil)

    let outcomes: [Result<[OpenAIModel], OpenAIModelsError>] = [
      .success([]),
      .success([model("gpt-5.6-luna"), model("whisper-1")]),
      .failure(.network),
      .failure(.unauthorized),
      .failure(.httpStatus(500)),
      .failure(.decodingFailed),
    ]
    for outcome in outcomes {
      let state = resolveModelListState(outcome: outcome)
      _ = pickerOptions(
        for: state,
        selection: OpenAIModelSetting.current(in: defaults),
        defaultModel: OpenAIModelSetting.defaultModel
      )
      #expect(defaults.string(forKey: OpenAIModelSetting.userDefaultsKey) == nil)
    }
  }
}
