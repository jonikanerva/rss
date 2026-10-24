import Foundation

/// Segmented filter state for the article list column.
enum ArticleFilter: String, CaseIterable {
  case unread = "Unread"
  case read = "Read"

  /// The other filter. The U key and the Article menu command switch to it.
  var toggled: ArticleFilter {
    switch self {
    case .unread: .read
    case .read: .unread
    }
  }

  /// The Article menu title of the command that switches to `toggled`.
  var toggleMenuTitle: String {
    switch self {
    case .unread: "Show Read Articles"
    case .read: "Show Unread Articles"
    }
  }
}
