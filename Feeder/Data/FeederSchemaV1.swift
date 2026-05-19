import Foundation
import SwiftData

/// First versioned schema for the Feeder persistent store.
///
/// `VersionedSchema` is the SwiftData primitive that lets us evolve the
/// schema without dropping the store. Future schema changes add a sibling
/// enum (e.g. `FeederSchemaV2`) and a stage in `FeederMigrationPlan`. V1
/// is the inception version, so it carries the live `@Model` types
/// unchanged via typealias — the existing `Feed` / `Entry` / `Category`
/// / `Folder` definitions stay exactly where they are. This keeps the
/// inception version a no-op refactor: the store on disk still tracks
/// the same Core Data entities, the only addition is the version identifier
/// metadata SwiftData uses to pick a migration path.
///
/// Bumping the schema next time:
/// 1. Add `FeederSchemaV2` next to this enum, declare any changed model
///    types nested inside `FeederSchemaV2` (and re-typealias unchanged
///    ones).
/// 2. Add a stage (`.lightweight` for additive/removal-only changes;
///    `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` when a
///    denormalized field — `plainText`, `formattedDate`, `primaryCategory`
///    — needs recomputing).
/// 3. Append `FeederSchemaV2.self` to `FeederMigrationPlan.schemas` and
///    the stage to `FeederMigrationPlan.stages`.
///
/// SwiftData stages live inside the container open; they do not flow
/// through `DataWriter`. That is the documented Apple pattern and the
/// reason `migrate` closures take a raw `ModelContext` rather than the
/// `DataWriter` actor — see PR #97 description for the architectural
/// exception note.
enum FeederSchemaV1: VersionedSchema {
  /// Initial schema version. Bump the major component when the on-disk
  /// shape changes in a way that requires a migration stage.
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  /// Every `@Model` type that participates in the store. Keep this list
  /// in lock-step with `FeederApp` and `PreviewSupport` / test container
  /// construction.
  static var models: [any PersistentModel.Type] {
    [Feed.self, Entry.self, Category.self, Folder.self]
  }
}
