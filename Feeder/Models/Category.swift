import Foundation
import SwiftData

/// Live `Category` is whatever the latest `VersionedSchema` declares —
/// see `Entry.swift` for the rationale behind the typealias-to-latest
/// pattern.
typealias Category = FeederSchemaV2.Category

// MARK: - Collection helpers

extension [Category] {
  /// Filter categories belonging to a specific folder, sorted by sortOrder.
  func inFolder(_ folderLabel: String) -> [Category] {
    filter { $0.folderLabel == folderLabel }
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  /// Root-level categories (no folder), sorted by sortOrder.
  var atRoot: [Category] {
    filter { $0.folderLabel == nil }
      .sorted { $0.sortOrder < $1.sortOrder }
  }
}
