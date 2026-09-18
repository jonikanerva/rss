import Foundation
import SwiftData

/// First versioned schema for the Feeder persistent store.
///
/// V1 is frozen. Any change to the nested `@Model` declarations invalidates the
/// on-disk contract for every store already migrated through V1, including the
/// lightweight V1→V2 stage. New schema work happens in the newest version, not
/// here. `STACK.md § 5` states how to add the next version.
enum FeederSchemaV1: VersionedSchema {
  /// Initial schema version.
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  /// Every `@Model` type in the V1 store shape. Keep it in lock-step with the
  /// nested declarations below.
  static var models: [any PersistentModel.Type] {
    [Feed.self, Entry.self, Category.self, Folder.self]
  }

  // MARK: - V1 models (frozen)

  /// V1's `Feed`, nested here so its relationship to V1's `Entry` resolves to
  /// the V1-scoped class and the on-disk contract holds.
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

  /// V1's `Entry`. Its `detectedLanguage` column exists in every V1 store on
  /// disk and must stay declared here, or the lightweight V1→V2 stage cannot
  /// drop it.
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

    /// V1-only stored property. It must stay declared, so the V1 schema
    /// description matches what every pre-V2 store holds on disk.
    var detectedLanguage: String?

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

  /// V1's `Folder`.
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

  /// V1's `Category`.
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
