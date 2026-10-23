import Foundation
import Testing

@testable import Feeder

/// A per-test isolated `UserDefaults` suite keeps parallel suites off the standard domain.
@Suite("VercelDecisionModel")
struct VercelDecisionModelTests {
  private let isolatedDefaults: IsolatedDefaults
  private var defaults: UserDefaults { isolatedDefaults.defaults }

  init() throws {
    isolatedDefaults = try IsolatedDefaults("VercelDecisionModel")
  }

  /// The gateway model IDs, from the AI Gateway model list.
  @Test
  func rawValuesAreTheGatewayModelIDs() {
    #expect(VercelDecisionModel.jev.rawValue == "typesafe-ai/jev")
    #expect(VercelDecisionModel.decision1.rawValue == "microsoft/microsoft-decision-1")
    #expect(VercelDecisionModel.lunaDecisions.rawValue == "openai/gpt-6-luna-decisions")
  }

  /// A user who never picked a model keeps JEV.
  @Test
  func absentKeyResolvesToJEV() {
    #expect(defaults.string(forKey: VercelDecisionModel.userDefaultsKey) == nil)
    #expect(VercelDecisionModel.current(in: defaults) == .jev)
  }

  @Test(arguments: ["", "typesafe-ai/unknown", "Decision-1"])
  func unknownStoredValueResolvesToJEV(stored: String) {
    defaults.set(stored, forKey: VercelDecisionModel.userDefaultsKey)
    #expect(VercelDecisionModel.current(in: defaults) == .jev)
  }

  @Test(arguments: VercelDecisionModel.allCases)
  func persistedPickRoundtrips(model: VercelDecisionModel) {
    VercelDecisionModel.persist(model, in: defaults)
    #expect(defaults.string(forKey: VercelDecisionModel.userDefaultsKey) == model.rawValue)
    #expect(VercelDecisionModel.current(in: defaults) == model)
  }
}
