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

/// Environment key carrying the set of entry IDs that the user marked unread
/// in this window, until the refetched rows show them unread. EntryRowView
/// reads this to render the row undimmed while the write is in flight.
private struct PendingUnreadIDsKey: EnvironmentKey {
  static let defaultValue: Set<Int> = []
}

extension EnvironmentValues {
  var pendingUnreadIDs: Set<Int> {
    get { self[PendingUnreadIDsKey.self] }
    set { self[PendingUnreadIDsKey.self] = newValue }
  }
}
