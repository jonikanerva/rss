import Foundation
import SwiftData

/// Migration plan for the Feeder persistent store, consumed by SwiftData when
/// it opens the `ModelContainer`. It declares every shipped schema version and
/// the stage between each adjacent pair. `STACK.md § 5` states how to add the
/// next version and when a stage must be custom rather than lightweight.
enum FeederMigrationPlan: SchemaMigrationPlan {
  /// Every shipped schema version, oldest first.
  static var schemas: [any VersionedSchema.Type] {
    [FeederSchemaV1.self, FeederSchemaV2.self, FeederSchemaV3.self]
  }

  /// Stages connecting adjacent schema versions. V1→V2 drops the dead
  /// `Entry.detectedLanguage` column, and V2→V3 drops the unread
  /// `Entry.formattedDate` column. Lightweight stages are safe because no
  /// other denormalized display field depends on either column.
  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: FeederSchemaV1.self, toVersion: FeederSchemaV2.self),
      .lightweight(fromVersion: FeederSchemaV2.self, toVersion: FeederSchemaV3.self),
    ]
  }
}
