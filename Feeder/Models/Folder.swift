import Foundation
import SwiftData

@Model
final class Folder {
  /// Unique folder key (e.g., "gaming")
  @Attribute(.unique)
  var label: String
  /// User-visible display name (e.g., "Gaming")
  var displayName: String
  /// Sort order for sidebar display
  var sortOrder: Int

  init(label: String, displayName: String, sortOrder: Int) {
    self.label = label
    self.displayName = displayName
    self.sortOrder = sortOrder
  }
}
