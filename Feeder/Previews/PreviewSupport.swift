import SwiftData
import SwiftUI

// MARK: - Preview-only (outside the layer rules per STACK.md § 0; preview/test exemptions per § 7)
//
// PreviewSupport centralises the in-memory ModelContainer used by every
// SwiftUI #Preview. Each preview retains its own fixture-insert code; only
// the container creation is shared, so a schema change touches one place
// (the Schema() array below) instead of every preview file.

@MainActor
enum PreviewSupport {
  static func makeContainer() -> ModelContainer {
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    do {
      return try ModelContainer(
        for: schema,
        migrationPlan: FeederMigrationPlan.self,
        configurations: configuration
      )
    } catch {
      fatalError("Preview ModelContainer failed: \(error)")
    }
  }

  /// Mint valid `PersistentIdentifier`s for the DTO-based previews.
  /// `PersistentIdentifier` has no public initializer, so an inserted row is
  /// the only supported source and this throwaway in-memory context is that
  /// source. The previews need the id values alone; every rendered field comes
  /// from the DTO, so the view still performs no store access.
  static func mintEntryIdentifiers(count: Int) -> [PersistentIdentifier] {
    let context = ModelContext(makeContainer())
    return (0..<count).map { offset in
      let entry = Entry(
        feedbinEntryID: 900_000 + offset, title: nil, author: nil,
        url: "https://example.invalid/\(offset)", content: nil, summary: nil,
        extractedContentURL: nil, publishedAt: .now, createdAt: .now
      )
      context.insert(entry)
      return entry.persistentModelID
    }
  }
}
