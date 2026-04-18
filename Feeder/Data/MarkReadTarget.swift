import Foundation

/// Scope for a bulk mark-as-read operation. Passed to `DataWriter.markAllAsRead`
/// so a single method handles both folder-level and category-level reads.
nonisolated enum MarkReadTarget: Sendable, Equatable {
  case folder(String)
  case category(String)
}
