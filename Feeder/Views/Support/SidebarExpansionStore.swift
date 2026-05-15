import Foundation
import SwiftUI

/// Persists which sidebar folders the user has collapsed.
///
/// We store *collapsed* labels (rather than expanded ones) so the default — an
/// empty set — means every folder is expanded. New folders surfaced after a
/// schema/migration are visible without the user touching settings, matching
/// the pre-disclosure-group behaviour.
///
/// Backed by a single `@AppStorage("sidebar.collapsedFolders")` key holding a
/// JSON array of label strings. Using one key avoids the per-folder cleanup
/// dance when a folder is renamed or deleted: stale labels in the set are
/// inert and harmless.
nonisolated struct SidebarCollapsedFolders: RawRepresentable, Equatable, Sendable {
  var labels: Set<String>

  var rawValue: String {
    let sorted = labels.sorted()
    guard let data = try? JSONEncoder().encode(sorted),
      let json = String(data: data, encoding: .utf8)
    else { return "[]" }
    return json
  }

  init(labels: Set<String> = []) {
    self.labels = labels
  }

  init?(rawValue: String) {
    guard let data = rawValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return nil }
    self.labels = Set(decoded)
  }

  func contains(_ label: String) -> Bool {
    labels.contains(label)
  }

  mutating func set(_ label: String, collapsed: Bool) {
    if collapsed {
      labels.insert(label)
    } else {
      labels.remove(label)
    }
  }
}

extension SidebarCollapsedFolders {
  /// Returns a `Binding<Bool>` for whether a given folder is expanded, suitable
  /// for `DisclosureGroup(isExpanded:)`. Reads / writes back into the same
  /// `@AppStorage` value via the supplied outer binding.
  static func expansionBinding(
    for label: String,
    store: Binding<SidebarCollapsedFolders>
  ) -> Binding<Bool> {
    Binding<Bool>(
      get: { !store.wrappedValue.contains(label) },
      set: { isExpanded in
        var copy = store.wrappedValue
        copy.set(label, collapsed: !isExpanded)
        store.wrappedValue = copy
      }
    )
  }
}
