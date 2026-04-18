import Foundation

/// Segmented filter state for the article list column.
enum ArticleFilter: String, CaseIterable {
  case unread = "Unread"
  case read = "Read"
}
