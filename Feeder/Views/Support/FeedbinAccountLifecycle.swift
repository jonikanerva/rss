import SwiftUI

/// Both account sheets must show this copy for a failed Keychain write.
nonisolated let feedbinKeychainSaveFailureMessage = "Could not save the Feedbin password to Keychain. Try again."

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
        if isSignedIn { startSync() }
      }
      .sheet(isPresented: .constant(needsOnboarding)) {
        OnboardingView()
          .environment(syncEngine)
          // Only a phase change may close the sheet.
          .interactiveDismissDisabled()
      }
  }
}
