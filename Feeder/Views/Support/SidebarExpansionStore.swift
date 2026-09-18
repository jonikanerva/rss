import Foundation
import SwiftUI

/// Persists which sidebar folders the user has collapsed.
///
/// It stores the collapsed labels, not the expanded ones, so the empty default
/// means every folder is expanded and a newly synced folder is visible without
/// the user touching Settings.
///
/// One storage key holds a JSON array of labels, so renaming or deleting a
/// folder needs no cleanup: a stale label in the set is inert.
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
  /// A `Binding<Bool>` for whether one folder is expanded, for
  /// `DisclosureGroup(isExpanded:)`. It reads and writes through the supplied
  /// outer binding.
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
