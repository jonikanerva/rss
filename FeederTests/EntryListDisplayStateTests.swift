import Testing

@testable import Feeder

// MARK: - EntryListDisplayState truth table

/// One row of the exhaustive truth table for
/// `entryListDisplayState(phase:hasSections:isAuthFailed:isOffline:)`.
nonisolated struct DisplayStateRow: Sendable, CustomTestStringConvertible {
  let phase: FetchPhase
  let hasSections: Bool
  let isAuthFailed: Bool
  let isOffline: Bool
  let expected: EntryListDisplayState

  var testDescription: String {
    "\(phase) sections=\(hasSections) auth=\(isAuthFailed) offline=\(isOffline) → \(expected)"
  }
}

/// Every combination of phase and flags, with the expectations written by hand,
/// so a precedence change must consciously edit a row here. The load-bearing
/// rows:
/// - Sections present render as a list under every phase and flag, so a
///   populated category never shows an empty-family pane.
/// - A pending empty fetch is blank under every flag, so a false "No Articles"
///   on a populated category is structurally unreachable.
/// - A resolved empty fetch with no sync error is "No Articles": engine
///   activity is absent from the signature, so a running classification cannot
///   suppress a true empty.
/// - A failed empty fetch is an error, ahead of the sync-error family, so a
///   store read failure never masquerades as offline or signed out.
/// - Auth failure outranks offline.
nonisolated let displayStateTruthTable: [DisplayStateRow] = [
  // pending, populated → list
  DisplayStateRow(
    phase: .pending, hasSections: true, isAuthFailed: true, isOffline: true, expected: .list),
  DisplayStateRow(
    phase: .pending, hasSections: true, isAuthFailed: true, isOffline: false, expected: .list),
  DisplayStateRow(
    phase: .pending, hasSections: true, isAuthFailed: false, isOffline: true, expected: .list),
  DisplayStateRow(
    phase: .pending, hasSections: true, isAuthFailed: false, isOffline: false, expected: .list),
  // pending, empty → blank (never an empty-family pane)
  DisplayStateRow(
    phase: .pending, hasSections: false, isAuthFailed: true, isOffline: true, expected: .blank),
  DisplayStateRow(
    phase: .pending, hasSections: false, isAuthFailed: true, isOffline: false, expected: .blank),
  DisplayStateRow(
    phase: .pending, hasSections: false, isAuthFailed: false, isOffline: true, expected: .blank),
  DisplayStateRow(
    phase: .pending, hasSections: false, isAuthFailed: false, isOffline: false, expected: .blank),
  // resolved, populated → list
  DisplayStateRow(
    phase: .resolved, hasSections: true, isAuthFailed: true, isOffline: true, expected: .list),
  DisplayStateRow(
    phase: .resolved, hasSections: true, isAuthFailed: true, isOffline: false, expected: .list),
  DisplayStateRow(
    phase: .resolved, hasSections: true, isAuthFailed: false, isOffline: true, expected: .list),
  DisplayStateRow(
    phase: .resolved, hasSections: true, isAuthFailed: false, isOffline: false, expected: .list),
  // resolved, empty → sync-error family, then noArticles
  DisplayStateRow(
    phase: .resolved, hasSections: false, isAuthFailed: true, isOffline: true,
    expected: .authFailed),
  DisplayStateRow(
    phase: .resolved, hasSections: false, isAuthFailed: true, isOffline: false,
    expected: .authFailed),
  DisplayStateRow(
    phase: .resolved, hasSections: false, isAuthFailed: false, isOffline: true,
    expected: .offline),
  DisplayStateRow(
    phase: .resolved, hasSections: false, isAuthFailed: false, isOffline: false,
    expected: .noArticles),
  // failed, populated → list (a failed refresh keeps showing existing rows)
  DisplayStateRow(
    phase: .failed, hasSections: true, isAuthFailed: true, isOffline: true, expected: .list),
  DisplayStateRow(
    phase: .failed, hasSections: true, isAuthFailed: true, isOffline: false, expected: .list),
  DisplayStateRow(
    phase: .failed, hasSections: true, isAuthFailed: false, isOffline: true, expected: .list),
  DisplayStateRow(
    phase: .failed, hasSections: true, isAuthFailed: false, isOffline: false, expected: .list),
  // failed, empty → error, outranking the sync-error family
  DisplayStateRow(
    phase: .failed, hasSections: false, isAuthFailed: true, isOffline: true, expected: .error),
  DisplayStateRow(
    phase: .failed, hasSections: false, isAuthFailed: true, isOffline: false, expected: .error),
  DisplayStateRow(
    phase: .failed, hasSections: false, isAuthFailed: false, isOffline: true, expected: .error),
  DisplayStateRow(
    phase: .failed, hasSections: false, isAuthFailed: false, isOffline: false, expected: .error),
]

struct EntryListDisplayStateTests {
  @Test(arguments: displayStateTruthTable)
  func exhaustivePrecedenceTruthTable(row: DisplayStateRow) {
    #expect(
      entryListDisplayState(
        phase: row.phase,
        hasSections: row.hasSections,
        isAuthFailed: row.isAuthFailed,
        isOffline: row.isOffline
      ) == row.expected
    )
  }

  /// A resolved empty fetch shows "No Articles", with no engine-activity input
  /// that could widen it back into a loading state, and a pending fetch never
  /// does. The phase distinction alone carries the false-empty protection.
  @Test
  func resolvedEmptyAssertsNoArticlesAndPendingNeverDoes() {
    #expect(
      entryListDisplayState(
        phase: .resolved, hasSections: false, isAuthFailed: false, isOffline: false
      ) == .noArticles
    )
    #expect(
      entryListDisplayState(
        phase: .pending, hasSections: false, isAuthFailed: false, isOffline: false
      ) == .blank
    )
  }
}
