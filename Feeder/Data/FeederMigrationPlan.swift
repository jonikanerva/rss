import Foundation
import SwiftData

/// Migration plan for the Feeder persistent store.
///
/// SwiftData consumes this when opening the `ModelContainer`. The plan
/// declares the ordered list of schema versions Feeder has ever shipped,
/// plus the stages that take a store between adjacent versions. The
/// V1→V2 stage is `.lightweight` because the only diff is the removal
/// of `Entry.detectedLanguage`, a column with no inputs flowing into
/// any denormalized display field — see `docs/stack.md` → Persistence
/// shape and `FeederSchemaV2` for the rationale.
///
/// When adding `FeederSchemaV3`:
/// - Append `FeederSchemaV3.self` to `schemas` (order matters — older
///   first).
/// - Append a `MigrationStage` to `stages`. Prefer
///   `.lightweight(fromVersion:toVersion:)` for additive / removal-only
///   changes. Use `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
///   when a denormalized display field (`plainText`, `formattedDate`,
///   `primaryCategory`, `primaryFolder`, `displayDomain`,
///   `formattedPublishedTime`, `summaryPlainText`, `articleBlocksData`)
///   needs recomputing because its inputs changed shape. The
///   `willMigrate` / `didMigrate` closures receive a raw `ModelContext`;
///   call the existing `nonisolated` helpers in
///   `Helpers/EntryFormatting.swift` and `Helpers/HTMLToBlocks.swift`
///   from inside them.
/// - Re-point the typealiases in `Feeder/Models/*.swift` to
///   `FeederSchemaV3.<Type>` so the live code sees the new shape.
enum FeederMigrationPlan: SchemaMigrationPlan {
  /// Every shipped schema version, oldest first.
  static var schemas: [any VersionedSchema.Type] {
    [FeederSchemaV1.self, FeederSchemaV2.self]
  }

  /// Migration stages connecting adjacent schema versions. V1→V2 drops
  /// the dead `Entry.detectedLanguage` column; lightweight stage is
  /// safe because no denormalized display field depends on it.
  static var stages: [MigrationStage] {
    [.lightweight(fromVersion: FeederSchemaV1.self, toVersion: FeederSchemaV2.self)]
  }
}
