import Foundation
import SwiftData

/// Migration plan for the Feeder persistent store.
///
/// SwiftData consumes this when opening the `ModelContainer`. The plan
/// declares the ordered list of schema versions Feeder has ever shipped,
/// plus the stages that take a store between adjacent versions. V1 has
/// no predecessor, so `stages` is empty — the structure is in place so
/// the next schema change is a lightweight or custom stage rather than a
/// destructive wipe.
///
/// When adding `FeederSchemaV2`:
/// - Append `FeederSchemaV2.self` to `schemas` (order matters — older
///   first).
/// - Append a `MigrationStage` to `stages`. Prefer
///   `.lightweight(fromVersion:toVersion:)` for additive / removal-only
///   changes. Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
///   when a denormalized display field (`plainText`, `formattedDate`,
///   `primaryCategory`, `primaryFolder`, `displayDomain`,
///   `formattedPublishedTime`) needs recomputing because its inputs
///   changed shape. The `willMigrate` / `didMigrate` closures receive a
///   raw `ModelContext`; call the existing `nonisolated` helpers in
///   `Helpers/EntryFormatting.swift` and `Helpers/HTMLToBlocks.swift`
///   from inside them.
enum FeederMigrationPlan: SchemaMigrationPlan {
  /// Every shipped schema version, oldest first.
  static var schemas: [any VersionedSchema.Type] {
    [FeederSchemaV1.self]
  }

  /// Migration stages connecting adjacent schema versions. Empty for the
  /// inception version — there is nothing to migrate yet.
  static var stages: [MigrationStage] {
    []
  }
}
