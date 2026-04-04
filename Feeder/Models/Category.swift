import Foundation
import SwiftData

@Model
final class Category {
  /// Unique label key (e.g., "playstation_5")
  @Attribute(.unique)
  var label: String
  /// User-visible display name
  var displayName: String
  /// User-editable description for LLM classification context
  var categoryDescription: String
  /// Sort order for sidebar display
  var sortOrder: Int
  /// Folder this category belongs to. nil = root-level category (no folder).
  var folderLabel: String?
  /// System categories cannot be deleted, moved, or renamed.
  var isSystem: Bool
  /// Keywords for keyword-match classification signal.
  var keywords: [String]

  init(
    label: String, displayName: String, categoryDescription: String,
    sortOrder: Int = 0, folderLabel: String? = nil, isSystem: Bool = false,
    keywords: [String] = []
  ) {
    self.label = label
    self.displayName = displayName
    self.categoryDescription = categoryDescription
    self.sortOrder = sortOrder
    self.folderLabel = folderLabel
    self.isSystem = isSystem
    self.keywords = keywords
  }
}
