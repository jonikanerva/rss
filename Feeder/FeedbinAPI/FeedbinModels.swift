import Foundation

/// A Feedbin subscription (feed the user subscribes to).
nonisolated struct FeedbinSubscription: Decodable, Sendable {
  let id: Int
  let feedId: Int
  let title: String
  let feedUrl: String
  let siteUrl: String
  let createdAt: Date
}

/// A Feedbin entry (article).
nonisolated struct FeedbinEntry: Decodable, Sendable {
  let id: Int
  let feedId: Int
  let title: String?
  let author: String?
  let content: String?
  let summary: String?
  let url: String
  let extractedContentUrl: String?
  let published: Date
  let createdAt: Date
}

/// A Feedbin favicon icon for a feed host.
nonisolated struct FeedbinIcon: Decodable, Sendable {
  let host: String
  let url: String
}

/// Result of a paginated entries fetch.
nonisolated struct FeedbinEntriesPage: Sendable {
  let entries: [FeedbinEntry]
  let hasNextPage: Bool
}

/// Extracted full content from Feedbin's Mercury Parser service.
nonisolated struct FeedbinExtractedContent: Decodable, Sendable {
  let title: String?
  let content: String?
  let author: String?
  let datePublished: String?
  let url: String?
  let domain: String?
  let excerpt: String?
  let wordCount: Int?
}
