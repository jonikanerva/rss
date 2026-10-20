import Foundation
import Testing

@testable import Feeder

/// Pins the once-per-app start of the signed-in session. Each new main window
/// reports the sign-in, so only a report while no periodic sync runs starts
/// the sync and the classification.
@MainActor
@Suite("Signed-in session start")
struct SignedInSessionStartTests {
  @Test
  func firstSignedInReportStartsTheSession() {
    #expect(startsSignedInSession(isSignedIn: true, isPeriodicSyncActive: false))
  }

  @Test
  func newWindowWhileTheSyncRunsStartsNothing() {
    #expect(!startsSignedInSession(isSignedIn: true, isPeriodicSyncActive: true))
  }

  @Test(arguments: [false, true])
  func signedOutReportStartsNothing(isPeriodicSyncActive: Bool) {
    #expect(!startsSignedInSession(isSignedIn: false, isPeriodicSyncActive: isPeriodicSyncActive))
  }

  /// The engine never starts the periodic sync here: its first step clears
  /// the shared URL cache, which is the owner's real store in the test host.
  @Test
  func otherSyncWorkDoesNotCountAsAPeriodicSync() {
    let engine = SyncEngine.preview()
    #expect(!engine.isPeriodicSyncActive)
    // Without a writer the backfill task ends at once, but the engine holds it
    // until `stopPeriodicSync()` clears it.
    engine.refetchHistory()
    #expect(engine.hasScheduledSyncWork)
    #expect(!engine.isPeriodicSyncActive)
    engine.stopPeriodicSync()
    #expect(!engine.isPeriodicSyncActive)
  }
}
