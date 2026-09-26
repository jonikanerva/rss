import Foundation

// MARK: - Model picker state machine

/// Phases of the Settings model-picker surface. The view sets `needsKey`,
/// `loading`, and `keyUnreadable` before a fetch; `resolveModelListState` maps
/// every fetch outcome.
nonisolated enum ModelListState: Equatable, Sendable {
  case needsKey
  case loading
  case loaded([String])
  case empty
  case failed(reason: String)

  /// The copy must not claim that no key is saved.
  static let keyUnreadable = ModelListState.failed(reason: "Models load when the API key can be read.")
}

/// Reduce a fetch outcome to a picker state. Pure: filtering (cosmetic
/// denylist) and newest-first sorting happen here, on the fetch path — never
/// in a view `body`. Never touches UserDefaults: resolving a state must not
/// write the model key (only an explicit user pick persists).
nonisolated func resolveModelListState(
  outcome: Result<[OpenAIModel], OpenAIModelsError>
) -> ModelListState {
  switch outcome {
  case .success(let models):
    let usable = sortModelsNewestFirst(filterClassificationModels(models))
    return usable.isEmpty ? .empty : .loaded(usable.map(\.id))
  case .failure(let error):
    switch error {
    case .unauthorized:
      return .failed(reason: "API key was rejected.")
    case .network:
      return .failed(reason: "Couldn't reach OpenAI. Models will load when you're back online.")
    case .httpStatus(let statusCode):
      return .failed(reason: "OpenAI returned an error (HTTP \(statusCode)).")
    case .decodingFailed:
      return .failed(reason: "Couldn't read the model list from OpenAI.")
    }
  }
}

/// Options the picker offers for a given state. INVARIANT: the returned list
/// always contains the persisted selection and the app default — a `Picker`
/// whose selection is not among its tags renders blank. In non-loaded states
/// this floor is the entire list, so the picker stays functional offline,
/// keyless, and mid-load.
nonisolated func pickerOptions(
  for state: ModelListState,
  selection: String,
  defaultModel: String
) -> [String] {
  let base: [String]
  switch state {
  case .loaded(let ids):
    base = ids
  case .needsKey, .loading, .empty, .failed:
    base = []
  }

  var seen = Set<String>()
  var options: [String] = []
  for id in base + [selection, defaultModel] where !id.isEmpty && seen.insert(id).inserted {
    options.append(id)
  }
  return options
}
