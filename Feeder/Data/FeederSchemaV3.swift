import Foundation
import SwiftData

/// Third versioned schema for the Feeder persistent store, and the live one.
///
/// V3 differs from V2 only by dropping `Entry.formattedDate`, which no view
/// reads. The removal is structural, so `FeederMigrationPlan` uses a
/// lightweight stage: no other display field depends on the column.
///
/// `Feed`, `Folder`, and `Category` are unchanged, yet declared here in full:
/// `Entry.feed` must resolve to V3's `Feed` for the model graph to stay
/// internally consistent.
///
/// Live code uses the unqualified `Entry`, `Feed`, `Folder`, and `Category`
/// typealiases in `Feeder/Models/`, which point at the nested types here.
enum FeederSchemaV3: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

  static var models: [any PersistentModel.Type] {
    [Feed.self, Entry.self, Category.self, Folder.self]
  }

  // MARK: - V3 models (live)

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
