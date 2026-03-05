import Foundation
import SwiftData

@Model
final class Feed {
    /// Feedbin subscription ID
    @Attribute(.unique) var feedbinSubscriptionID: Int
    /// Feedbin feed ID
    var feedbinFeedID: Int
    /// User-visible feed title (may be user-edited in Feedbin)
    var title: String
    /// Feed URL
    var feedURL: String
    /// Site URL
    var siteURL: String
    /// Date subscription was created in Feedbin
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Entry.feed)
    var entries: [Entry] = []

    init(
        feedbinSubscriptionID: Int,
        feedbinFeedID: Int,
        title: String,
        feedURL: String,
        siteURL: String,
        createdAt: Date
    ) {
        self.feedbinSubscriptionID = feedbinSubscriptionID
        self.feedbinFeedID = feedbinFeedID
        self.title = title
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.createdAt = createdAt
    }
}
