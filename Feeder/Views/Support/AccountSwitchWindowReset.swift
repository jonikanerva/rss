import SwiftData
import SwiftUI

/// Registers this window with `SyncEngine`, so that an account switch clears
/// the selection and the read intents of the window before it deletes the
/// previous account's entries, and reloads the list after the delete. A live
/// `Entry` model must not outlive its row.
struct AccountSwitchWindowReset: ViewModifier {
  @Environment(SyncEngine.self)
  private var syncEngine
  let timeline: TimelineState
  @Binding
  var selectedEntryID: PersistentIdentifier?
  @Binding
  var selectedEntry: Entry?

  func body(content: Content) -> some View {
    content
      .onAppear {
        let selectedEntryID = $selectedEntryID
        let selectedEntry = $selectedEntry
        let timeline = timeline
        syncEngine.registerAccountSwitchReset(
          forWindow: timeline.windowID,
          beforeDelete: {
            selectedEntryID.wrappedValue = nil
            selectedEntry.wrappedValue = nil
            timeline.resetForAccountSwitch()
          },
          afterDelete: { timeline.accountDataDeleted() })
      }
      .onDisappear { syncEngine.unregisterAccountSwitchReset(forWindow: timeline.windowID) }
  }
}
