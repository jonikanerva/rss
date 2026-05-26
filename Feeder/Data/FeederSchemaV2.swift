import Foundation
import SwiftData

/// Second versioned schema for the Feeder persistent store.
///
/// V2's only diff from V1 is the removal of `Entry.detectedLanguage` —
/// a write-only column that no read site ever consumed (issue #90). The
/// removal is structural (`.lightweight` stage in `FeederMigrationPlan`)
/// because the field is not an input to any denormalized display field
/// (`plainText`, `formattedDate`, `formattedPublishedTime`,
/// `primaryCategory`, `primaryFolder`, `displayDomain`, `summaryPlainText`,
/// `articleBlocksData`), so no recomputation is needed.
///
/// `Feed`, `Folder`, and `Category` are unchanged at the V1→V2 boundary,
/// but they are still declared here in their entirety rather than
/// typealiased to V1. The reason: V2's `Entry.feed` relationship must
/// resolve to V2's `Feed` so the entire V2 model graph is internally
/// consistent. Apple's "Trips" SwiftData sample applies the same pattern.
/// SwiftData maps V1.Feed ↔ V2.Feed by class shape during the
/// lightweight stage — no migration cost for the unchanged tables.
///
/// All live (non-migration) code references the unqualified `Entry`,
/// `Feed`, `Folder`, `Category` symbols defined as typealiases in
/// `Feeder/Models/*.swift`. Those typealiases point at the V2 nested
/// types here. The next schema version re-points them.
enum FeederSchemaV2: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

  static var models: [any PersistentModel.Type] {
    [Feed.self, Entry.self, Category.self, Folder.self]
  }

  // MARK: - V2 models (live)

  @Model
  final class Feed {
    @Attribute(.unique)
    var feedbinSubscriptionID: Int
    var feedbinFeedID: Int
    var title: String
    var feedURL: String
    var siteURL: String
    var createdAt: Date
    var faviconURL: String?
    var faviconData: Data?

    @Relationship(deleteRule: .cascade)
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

  @Model
  final class Entry {
    @Attribute(.unique)
    var feedbinEntryID: Int
    var title: String?
    var author: String?
    var url: String
    var content: String?
    var summary: String?
    var extractedContent: String?
    var extractedContentURL: String?
    var publishedAt: Date
    var createdAt: Date
    var isRead: Bool = false
    var isClassified: Bool = false
    var plainText: String = ""
    var summaryPlainText: String = ""
    var articleBlocksData: Data?
    var formattedDate: String = ""
    var formattedPublishedTime: String = ""
    var displayDomain: String?
    var primaryCategory: String = ""
    var primaryFolder: String = ""

    var feed: Feed?

    init(
      feedbinEntryID: Int,
      title: String?,
      author: String?,
      url: String,
      content: String?,
      summary: String?,
      extractedContentURL: String?,
      publishedAt: Date,
      createdAt: Date
    ) {
      self.feedbinEntryID = feedbinEntryID
      self.title = title
      self.author = author
      self.url = url
      self.content = content
      self.summary = summary
      self.extractedContentURL = extractedContentURL
      self.publishedAt = publishedAt
      self.createdAt = createdAt
    }
  }

  @Model
  final class Folder {
    @Attribute(.unique)
    var label: String
    var displayName: String
    var sortOrder: Int

    init(label: String, displayName: String, sortOrder: Int) {
      self.label = label
      self.displayName = displayName
      self.sortOrder = sortOrder
    }
  }

  @Model
  final class Category {
    @Attribute(.unique)
    var label: String
    var displayName: String
    var categoryDescription: String
    var sortOrder: Int
    var folderLabel: String?
    var isSystem: Bool
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
}
