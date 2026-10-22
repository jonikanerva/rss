import Foundation

/// The value that the main `WindowGroup` presents. Feeder has one main window,
/// so the value has one case.
nonisolated enum MainWindow: String, Codable, Hashable, Sendable {
  case main

  static let sceneID = "main"
}
