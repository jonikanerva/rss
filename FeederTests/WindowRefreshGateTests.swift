import Foundation
import Testing

@testable import Feeder

/// Truth table for the pure window-refresh gate plus the key-composition
/// pins the issue #163 scheduling fix depends on: `shouldRunWindowRefresh`
/// decides whether an `entryRefreshVersion` bump refetches the visible
/// window; the resolve-flip re-fire works only while `resolvedStructuralKey`
/// is a `refreshTaskKey` component; the flush's snapshot-only channel works
/// only while `snapshotRefreshVersion` is an `unreadSnapshotKey` component.
@Suite("Window-refresh gate (pure)")
struct WindowRefreshGateTests {
  private let key = "tech||unread|0.0"

  // MARK: - Gate truth table

  @Test
  func keyMismatchSkips() {
    // A structural fetch owns the window ("" while in flight, or a stale
    // resolved key after a context change) — refreshes stand down.
    #expect(
      !shouldRunWindowRefresh(
        resolvedKey: "", currentKey: key, phase: .resolved,
        refreshVersion: 1, consumedVersion: 0))
    #expect(
      !shouldRunWindowRefresh(
        resolvedKey: "world||unread|0.0", currentKey: key, phase: .resolved,
        refreshVersion: 1, consumedVersion: 0))
  }

  @Test
  func pendingPhaseSkips() {
    #expect(
      !shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .pending,
        refreshVersion: 1, consumedVersion: 0))
  }

  @Test
  func consumedVersionSkips() {
    #expect(
      !shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .resolved,
        refreshVersion: 3, consumedVersion: 3))
  }

  @Test
  func matchingResolvedOwedRuns() {
    #expect(
      shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .resolved,
        refreshVersion: 4, consumedVersion: 3))
  }

  /// Healing pin: an owed bump must be able to heal a failed pane — the
  /// structural task hands ownership back on failure precisely so a later
  /// successful refresh can flip `.failed` → `.resolved`.
  @Test
  func matchingFailedOwedRuns() {
    #expect(
      shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .failed,
        refreshVersion: 4, consumedVersion: 3))
  }

  // MARK: - Filter-flip ordering (issue #163, O3)

  /// Bump lands BEFORE the structural pre-fetch snapshot: the snapshot
  /// captures the bumped version, so after resolve `consumed == refreshVersion`
  /// — the first-page fetch already included the committed data, and the
  /// gate correctly skips.
  @Test
  func bumpBeforePreFetchSnapshotIsConsumed() {
    let bumpedVersion = 7
    let preFetchSnapshot = bumpedVersion
    #expect(
      !shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .resolved,
        refreshVersion: bumpedVersion, consumedVersion: preFetchSnapshot))
  }

  /// Bump lands AFTER the pre-fetch snapshot: it stays owed
  /// (`refreshVersion > consumed`), and the resolve-flip re-keys the refresh
  /// task ("" → key changes `refreshTaskKey`) so exactly one refresh
  /// re-fires to pick it up.
  @Test
  func bumpAfterPreFetchSnapshotIsOwedAndRefires() {
    let preFetchSnapshot = 7
    let bumpedVersion = 8
    #expect(
      shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .resolved,
        refreshVersion: bumpedVersion, consumedVersion: preFetchSnapshot))
    // The re-fire mechanism: the resolve-flip alone changes the task key.
    let duringFetch = EntryListView.composeRefreshTaskKey(
      structuralKey: key, resolvedStructuralKey: "", refreshVersion: bumpedVersion)
    let afterResolve = EntryListView.composeRefreshTaskKey(
      structuralKey: key, resolvedStructuralKey: key, refreshVersion: bumpedVersion)
    #expect(duringFetch != afterResolve)
  }

  /// Redundant bumps coalesce (ux regression case 4): a burst of bumps is
  /// consumed by ONE successful refresh — the recorded consumed version is
  /// the latest, so the gate closes for the whole burst.
  @Test
  func bumpBurstCoalescesToOneRefresh() {
    let consumedBeforeBurst = 2
    let latestBumpedVersion = 5
    #expect(
      shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .resolved,
        refreshVersion: latestBumpedVersion, consumedVersion: consumedBeforeBurst))
    // The successful refresh records the version it ran against…
    let consumedAfterRefresh = latestBumpedVersion
    // …and the gate is closed for every bump in the burst.
    #expect(
      !shouldRunWindowRefresh(
        resolvedKey: key, currentKey: key, phase: .resolved,
        refreshVersion: latestBumpedVersion, consumedVersion: consumedAfterRefresh))
  }

  // MARK: - Key composition pins

  /// `snapshotRefreshVersion` must be an `unreadSnapshotKey` component — the
  /// flush's snapshot-only channel re-keys the snapshot task through it.
  @Test
  func unreadSnapshotKeyIncludesSnapshotRefreshVersion() {
    let before = ContentView.composeUnreadSnapshotKey(
      entryRefreshVersion: 1, snapshotRefreshVersion: 0,
      folderCount: 2, categoryCount: 5, cutoffSeconds: 1000)
    let after = ContentView.composeUnreadSnapshotKey(
      entryRefreshVersion: 1, snapshotRefreshVersion: 1,
      folderCount: 2, categoryCount: 5, cutoffSeconds: 1000)
    #expect(before != after)
  }

  /// `resolvedStructuralKey` must be a `refreshTaskKey` component — the
  /// resolve-flip re-fire depends on it; the other components alone must
  /// also still re-key (structural cancel, bump).
  @Test
  func refreshTaskKeyIncludesAllThreeComponents() {
    let base = EntryListView.composeRefreshTaskKey(
      structuralKey: key, resolvedStructuralKey: key, refreshVersion: 1)
    #expect(
      base
        != EntryListView.composeRefreshTaskKey(
          structuralKey: "world||unread|0.0", resolvedStructuralKey: key, refreshVersion: 1))
    #expect(
      base
        != EntryListView.composeRefreshTaskKey(
          structuralKey: key, resolvedStructuralKey: "", refreshVersion: 1))
    #expect(
      base
        != EntryListView.composeRefreshTaskKey(
          structuralKey: key, resolvedStructuralKey: key, refreshVersion: 2))
  }
}
