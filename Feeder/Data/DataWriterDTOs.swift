import Foundation
import SwiftData

// MARK: - Sendable DTOs for crossing actor boundaries

/// Input data for classification — extracted from Entry on background actor, consumed by FM inference.
nonisolated struct ClassificationInput: Sendable {
  let entryID: Int
  let title: String
  let body: String
  let url: String
}

/// Classification result — produced by FM inference, applied to Entry on background actor.
nonisolated struct ClassificationResult: Sendable {
  let entryID: Int
  let categoryLabel: String
  let storyKey: String
  let detectedLanguage: String
  let confidence: Double
}

/// Category definition — read from SwiftData, passed to classification as Sendable.
nonisolated struct CategoryDefinition: Sendable {
  let label: String
  let description: String
  let folderLabel: String?
  let keywords: [String]

  init(label: String, description: String, folderLabel: String? = nil, keywords: [String] = []) {
    self.label = label
    self.description = description
    self.folderLabel = folderLabel
    self.keywords = keywords
  }
}

/// One day-grouped section of the article list. Built off-MainActor by
/// `DataWriter.fetchEntrySections` and consumed by `EntryListView`.
/// Only carries lightweight identifiers — the view materializes Entry objects
/// per-row on MainActor via `modelContext.model(for:)` (lazy, only visible rows).
nonisolated struct EntryListSection: Sendable, Identifiable, Equatable {
  let id: Date  // start-of-day, used as ForEach identity
  let label: String
  let entryIDs: [PersistentIdentifier]
}
