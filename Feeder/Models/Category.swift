import Foundation
import SwiftData

@Model
final class Category {
  /// Unique label key (kebab-case, e.g., "gaming_industry")
  @Attribute(.unique)
  var label: String
  /// User-visible display name
  var displayName: String
  /// User-editable description for LLM classification context
  var categoryDescription: String
  /// Sort order for sidebar display
  var sortOrder: Int
  /// Parent category label. nil = top-level.
  var parentLabel: String?
  /// Hierarchy depth: 0 = top-level, 1 = child.
  var depth: Int
  /// Whether this is a top-level category (pre-computed for @Query).
  var isTopLevel: Bool
  /// System categories cannot be deleted, moved, or renamed.
  var isSystem: Bool

  init(
    label: String, displayName: String, categoryDescription: String,
    sortOrder: Int = 0, parentLabel: String? = nil, isSystem: Bool = false
  ) {
    self.label = label
    self.displayName = displayName
    self.categoryDescription = categoryDescription
    self.sortOrder = sortOrder
    self.parentLabel = parentLabel
    self.depth = parentLabel == nil ? 0 : 1
    self.isTopLevel = parentLabel == nil
    self.isSystem = isSystem
  }
}
