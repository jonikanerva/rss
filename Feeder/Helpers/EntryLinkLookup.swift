import Foundation
import SwiftData

// MARK: - Entry link lookup (pure)

/// `nil` when the stored link is empty or does not parse as a URL.
nonisolated func entryLinkURL(from storedLink: String) -> URL? {
  guard !storedLink.isEmpty else { return nil }
  return URL(string: storedLink)
}

/// The single row in `ids`. `nil` unless `ids` holds exactly one ID and that
/// ID belongs to a row in `sections`.
nonisolated func entryRow(
  for ids: Set<PersistentIdentifier>, in sections: [EntryListSection]
) -> EntryRowDTO? {
  guard ids.count == 1, let id = ids.first else { return nil }
  return sections.lazy.flatMap(\.rows).first(where: { $0.persistentID == id })
}

/// The link of the single row in `ids`. `nil` unless `entryRow(for:in:)` finds
/// the row and the row's link parses.
nonisolated func entryLinkURL(
  for ids: Set<PersistentIdentifier>, in sections: [EntryListSection]
) -> URL? {
  entryRow(for: ids, in: sections).flatMap { entryLinkURL(from: $0.url) }
}
