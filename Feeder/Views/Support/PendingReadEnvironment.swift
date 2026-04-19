import SwiftUI

/// Environment key carrying the set of entry IDs the user has opened this session
/// but that haven't been flushed to the DataWriter yet. EntryRowView reads this to
/// render the "optimistic read" dim state while the mark-read task is in flight.
private struct PendingReadIDsKey: EnvironmentKey {
  static let defaultValue: Set<Int> = []
}

extension EnvironmentValues {
  var pendingReadIDs: Set<Int> {
    get { self[PendingReadIDsKey.self] }
    set { self[PendingReadIDsKey.self] = newValue }
  }
}
