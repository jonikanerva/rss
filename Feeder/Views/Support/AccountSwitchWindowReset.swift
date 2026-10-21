import SwiftData
import SwiftUI

/// Registers this window with `SyncEngine`, so that an account switch clears
/// the selection and the optimistic reads of the window before it deletes the
/// previous account's entries. A live `Entry` model must not outlive its row.
struct AccountSwitchWindowReset: ViewModifier {
  @Environment(SyncEngine.self)
  private var syncEngine
  @State
  private var windowID = UUID()
  @Binding
  var selectedEntryID: PersistentIdentifier?
  @Binding
  var selectedEntry: Entry?
  @Binding
  var pendingReadIDs: Set<Int>

  func body(content: Content) -> some View {
    content
      .onAppear {
        let selectedEntryID = $selectedEntryID
        let selectedEntry = $selectedEntry
        let pendingReadIDs = $pendingReadIDs
        syncEngine.registerAccountSwitchReset(forWindow: windowID) {
          selectedEntryID.wrappedValue = nil
          selectedEntry.wrappedValue = nil
          pendingReadIDs.wrappedValue = []
        }
      }
      .onDisappear { syncEngine.unregisterAccountSwitchReset(forWindow: windowID) }
  }
}
