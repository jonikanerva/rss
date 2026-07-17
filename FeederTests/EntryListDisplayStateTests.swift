import Testing

@testable import Feeder

// MARK: - EntryListDisplayState truth table (issue #146)

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

/// All 24 combinations (3 phases × 2³ flags), expectations written by hand so
/// any precedence change must consciously edit a row here. Load-bearing rows:
/// - `hasSections` → `.list` under EVERY phase and flag combination
///   (continuity: fetched rows always render — a populated category never
///   shows an empty-family pane).
/// - `pending` + empty → `.blank` under every flag combination: an unresolved
///   fetch asserts nothing, so a false "No Articles" flash on a populated
///   category is structurally unreachable (the relocated #137 protection —
///   issue #146 reverses #137's copy, not its guarantee).
/// - `resolved` + empty + no sync error → `.noArticles` — engine activity is
///   deliberately absent from the signature, so "classification is running"
///   cannot suppress a true empty (the #137 reversal pin).
/// - `failed` + empty → `.error` BEFORE the sync-error family: a store read
///   failure must not masquerade as "offline" or "signed out".
/// - `resolved` + empty + authFailed + offline → `.authFailed` (auth outranks
///   offline).
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

  /// The #137 reversal pin, stated by itself: a RESOLVED empty fetch shows
  /// "No Articles" — there is no engine-activity input that could widen it
  /// back into a loading state — while a PENDING fetch never does. Together
  /// these relocate #137's false-empty protection from the deleted "Sorting
  /// your articles" copy into the phase distinction.
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
