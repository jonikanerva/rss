import Foundation

/// Scope for a bulk mark-as-read operation. Passed to `DataWriter.markAllAsRead`
/// so a single method handles both folder-level and category-level reads.
nonisolated enum MarkReadTarget: Sendable, Equatable {
  case folder(String)
  case category(String)

  /// Human-readable description for log output, e.g. "folder 'technology'".
  var logDescription: String {
    switch self {
    case .folder(let label): "folder '\(label)'"
    case .category(let label): "category '\(label)'"
    }
  }
}
