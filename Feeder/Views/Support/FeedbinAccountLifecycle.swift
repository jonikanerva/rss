import SwiftUI

/// Both account sheets must show this copy for a failed Keychain write.
nonisolated let feedbinKeychainSaveFailureMessage = "Could not save the Feedbin password to Keychain. Try again."

/// Each new main window reports the sign-in, also after a Dock reopen. The
/// session starts only while no periodic sync runs, so a new window never
/// restarts the sync or the classification. `startSync` must start the
/// periodic sync synchronously, before its first suspension.
nonisolated func startsSignedInSession(isSignedIn: Bool, isPeriodicSyncActive: Bool) -> Bool {
  isSignedIn && !isPeriodicSyncActive
}

struct FeedbinAccountLifecycle: ViewModifier {
  @Environment(SyncEngine.self)
  private var syncEngine
  let startSync: () -> Void

  func body(content: Content) -> some View {
    // Read the phase in the body so that observation tracks it: the sheet must
    // close as soon as the phase leaves `.noAccount`.
    let needsOnboarding = syncEngine.account == .noAccount
    content
      .task { await syncEngine.loadAccountAtLaunch() }
      .onChange(of: syncEngine.account.isSignedIn, initial: true) { _, isSignedIn in
        if startsSignedInSession(isSignedIn: isSignedIn, isPeriodicSyncActive: syncEngine.isPeriodicSyncActive) {
          startSync()
        }
      }
      .sheet(isPresented: .constant(needsOnboarding)) {
        OnboardingView()
          .environment(syncEngine)
          // Only a phase change may close the sheet.
          .interactiveDismissDisabled()
      }
  }
}
