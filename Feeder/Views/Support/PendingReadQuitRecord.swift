import SwiftUI

/// Copies the pending reads of this window to `SyncEngine` on each change, so
/// that the quit step can queue them. The modifier owns the window ID, so each
/// window keeps its own copy.
struct PendingReadQuitRecord: ViewModifier {
  @Environment(SyncEngine.self)
  private var syncEngine
  @State
  private var windowID = UUID()
  let pendingReadIDs: Set<Int>

  func body(content: Content) -> some View {
    content.onChange(of: pendingReadIDs) { _, ids in
      syncEngine.recordPendingReads(ids, forWindow: windowID)
    }
  }
}
