import Foundation
import SwiftData

// MARK: - Entry link lookup (pure)

/// `nil` when the stored link is empty or does not parse as a URL.
nonisolated func entryLinkURL(from storedLink: String) -> URL? {
  guard !storedLink.isEmpty else { return nil }
  return URL(string: storedLink)
}

/// The link of the single row in `ids`. `nil` unless `ids` holds exactly one
/// ID, that ID belongs to a row in `sections`, and the row's link parses.
nonisolated func entryLinkURL(
  for ids: Set<PersistentIdentifier>, in sections: [EntryListSection]
) -> URL? {
  guard ids.count == 1, let id = ids.first,
    let row = sections.lazy.flatMap(\.rows).first(where: { $0.persistentID == id })
  else { return nil }
  return entryLinkURL(from: row.url)
}
