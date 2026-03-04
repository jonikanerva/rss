import Foundation
import SwiftData

@Model
final class Category {
    /// Unique label key (kebab-case, e.g., "gaming_industry")
    @Attribute(.unique) var label: String
    /// User-visible display name
    var displayName: String
    /// User-editable description for LLM classification context
    var categoryDescription: String
    /// Sort order for sidebar display
    var sortOrder: Int

    init(label: String, displayName: String, categoryDescription: String, sortOrder: Int = 0) {
        self.label = label
        self.displayName = displayName
        self.categoryDescription = categoryDescription
        self.sortOrder = sortOrder
    }
}
