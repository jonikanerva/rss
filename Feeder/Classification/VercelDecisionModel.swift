import Foundation

/// The decision model that Vercel AI Gateway runs for classification.
/// The raw value is the gateway model ID and the value stored in UserDefaults.
nonisolated enum VercelDecisionModel: String, Sendable, CaseIterable {
  case jev = "typesafe-ai/jev"
  case decision1 = "microsoft/microsoft-decision-1"

  static let userDefaultsKey = "vercel_model"
  static let `default`: Self = .jev

  /// An absent or unknown stored value resolves to `default`.
  static func current(in defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: userDefaultsKey).flatMap(Self.init(rawValue:)) ?? .default
  }

  static func persist(_ model: Self, in defaults: UserDefaults = .standard) {
    defaults.set(model.rawValue, forKey: userDefaultsKey)
  }

  // MARK: - Display

  var displayName: String {
    switch self {
    case .jev: "JEV (Typesafe)"
    case .decision1: "Decision-1 (Microsoft)"
    }
  }

  var shortName: String {
    switch self {
    case .jev: "JEV"
    case .decision1: "Decision-1"
    }
  }

  /// The model provider that receives the article data through the gateway.
  var recipientName: String {
    switch self {
    case .jev: "Typesafe"
    case .decision1: "Microsoft"
    }
  }
}
