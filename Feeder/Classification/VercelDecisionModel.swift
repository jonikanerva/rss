import Foundation

/// The decision model that Vercel AI Gateway runs for classification.
/// The raw value is the gateway model ID and the value stored in UserDefaults.
/// Use the unversioned gateway ID when the model provider offers one, so the
/// gateway serves its newest version (`STACK.md → Cloud classification`).
nonisolated enum VercelDecisionModel: String, Sendable, CaseIterable {
  case jev = "typesafe-ai/jev"
  case decision1 = "microsoft/microsoft-decision-1"
  case lunaDecisions = "openai/gpt-6-luna-decisions"

  static let userDefaultsKey = "vercel_model"
  static let `default`: Self = .jev

  /// An absent or unknown stored value resolves to `default`.
  static func current(in defaults: UserDefaults = AppDefaults.current) -> Self {
    defaults.string(forKey: userDefaultsKey).flatMap(Self.init(rawValue:)) ?? .default
  }

  static func persist(_ model: Self, in defaults: UserDefaults = AppDefaults.current) {
    defaults.set(model.rawValue, forKey: userDefaultsKey)
  }

  // MARK: - Display

  var displayName: String {
    switch self {
    case .jev: "JEV (Typesafe)"
    case .decision1: "Decision-1 (Microsoft)"
    case .lunaDecisions: "GPT-6 Luna Decisions (OpenAI)"
    }
  }

  var shortName: String {
    switch self {
    case .jev: "JEV"
    case .decision1: "Decision-1"
    case .lunaDecisions: "GPT-6 Luna Decisions"
    }
  }

  /// The model provider that receives the article data through the gateway.
  var recipientName: String {
    switch self {
    case .jev: "Typesafe"
    case .decision1: "Microsoft"
    case .lunaDecisions: "OpenAI"
    }
  }
}
