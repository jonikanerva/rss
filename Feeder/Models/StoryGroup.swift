import Foundation
import SwiftData

@Model
final class StoryGroup {
    /// Generated story key (kebab-case, e.g., "openai-dod-contract")
    @Attribute(.unique) var storyKey: String
    /// Generated human-readable headline for the group
    var headline: String
    /// Earliest article date in the group (used for timeline ordering per VISION.md)
    var earliestDate: Date
    /// Number of entries in this group (denormalized for performance)
    var entryCount: Int = 0

    init(storyKey: String, headline: String, earliestDate: Date) {
        self.storyKey = storyKey
        self.headline = headline
        self.earliestDate = earliestDate
    }
}
