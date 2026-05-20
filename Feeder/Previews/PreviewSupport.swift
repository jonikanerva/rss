import SwiftData
import SwiftUI

// MARK: - Preview-only (outside two-layer rule per docs/definition-of-done.md)
//
// PreviewSupport centralises the in-memory ModelContainer used by every
// SwiftUI #Preview. Each preview retains its own fixture-insert code; only
// the container creation is shared, so a schema change touches one place
// (the Schema() array below) instead of every preview file.

@MainActor
enum PreviewSupport {
  static func makeContainer() -> ModelContainer {
    let schema = Schema(versionedSchema: FeederSchemaV1.self)
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
}
