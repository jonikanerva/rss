import Foundation

/// The set of articles that one article list or one bulk mark-as-read covers.
/// `.all` covers every article inside the retention window, also an article
/// with no category assignment. `.folder` and `.category` cover only the
/// articles assigned to that label.
nonisolated enum EntryScope: Sendable, Equatable {
  case all
  case folder(String)
  case category(String)

  /// Human-readable description for log output, e.g. "folder 'technology'".
  var logDescription: String {
    switch self {
    case .all: "all articles"
    case .folder(let label): "folder '\(label)'"
    case .category(let label): "category '\(label)'"
    }
  }
}
