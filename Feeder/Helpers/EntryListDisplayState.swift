import Foundation

// MARK: - Fetch Phase

/// Lifecycle of the article-list background fetch for the current structural
/// context (category / folder / filter / cutoff). Replaces the old boolean
/// `hasLoaded` with a tagged union (`CLAUDE.md → Architecture`) so "the fetch
/// has not resolved yet" is distinguishable from "the fetch resolved empty" —
/// the distinction that makes a false "No Articles" flash on a populated
/// category structurally unreachable (issue #146; this relocates the #137
/// protection from the "Sorting your articles" copy into the state machine).
nonisolated enum FetchPhase: Sendable, Equatable {
  /// A structural fetch is in flight; nothing is known about the new context yet.
  case pending
  /// The most recent structural or refresh fetch applied its result.
  case resolved
  /// The structural fetch failed with a store error (no retry — the shared
  /// coordinator blocks rather than throws under contention, so a throw is
  /// almost certainly persistent). Healed by any later successful refresh
  /// reload, or by re-selecting the category.
  case failed
}

// MARK: - Display State

/// What the article-list pane shows, derived once per render by
/// `entryListDisplayState(phase:hasSections:isAuthFailed:isOffline:)`.
nonisolated enum EntryListDisplayState: Sendable, Equatable {
  /// Pending fetch with no rows yet: the mounted `List` renders zero rows —
  /// a calm blank pane, never a spinner and never "No Articles".
  case blank
  /// At least one section: the mounted `List` renders rows.
  case list
  /// Genuinely empty at rest — the store has no rows for this context.
  case noArticles
  /// Empty and the last sync failed with a network error.
  case offline
  /// Empty and the last sync failed with invalid Feedbin credentials.
  case authFailed
  /// Empty and the fetch itself failed — store error, not sync state.
  case error

  /// Whether the pane draws an empty-family pane in the `.overlay` above the
  /// always-mounted zero-row `List` (`EntryListView` explains why the empty
  /// family must never replace the `List` in a sibling branch). Doubles as
  /// the `.disabled` / `.accessibilityHidden` gate on the covered `List`: a
  /// disabled list leaves the Tab loop and its key handlers cannot fire — an
  /// ungated ⇧A would mark the whole category read behind an error pane,
  /// because `markAllAsRead` targets the sidebar-selection predicate, not
  /// rendered rows.
  var showsEmptyOverlay: Bool {
    switch self {
    case .noArticles, .offline, .authFailed, .error: true
    case .blank, .list: false
    }
  }
}

/// Pure precedence rule for the article-list pane (issue #146).
///
/// Precedence, most binding first:
/// 1. `hasSections` → `.list` — continuity over blankness: fetched rows always
///    render, whatever the phase or sync-error family says.
/// 2. `.pending` → `.blank` — an unresolved fetch asserts nothing; showing
///    "No Articles" (or any empty-family pane) here would be a false claim
///    about a context we have not read yet (the relocated #137 protection).
/// 3. `.failed` → `.error` — a store read failure outranks the sync-error
///    family: "couldn't load" must not masquerade as "offline" or "empty".
/// 4. `isAuthFailed` → `.authFailed`, then `isOffline` → `.offline`, then
///    `.noArticles`.
///
/// Deliberately NO engine flags (`isClassifying` / `isSyncing`) in the
/// signature: a resolved-empty fetch means the store has no rows for this
/// context right now, and the deferred-bump drain channel re-fetches as
/// classification lands rows — so asserting emptiness is safe, and the pane
/// live-populates the moment the first article exists.
nonisolated func entryListDisplayState(
  phase: FetchPhase,
  hasSections: Bool,
  isAuthFailed: Bool,
  isOffline: Bool
) -> EntryListDisplayState {
  if hasSections { return .list }
  switch phase {
  case .pending: return .blank
  case .failed: return .error
  case .resolved: break
  }
  if isAuthFailed { return .authFailed }
  if isOffline { return .offline }
  return .noArticles
}

// MARK: - Window-refresh gate

/// Pure scheduling gate for the whole-window refresh channel (issue #163).
/// Placed here rather than in `EntryListPaging.swift` because it is
/// fetch-LIFECYCLE logic (it reads `FetchPhase`), not paging math.
///
/// A refresh may run only when ALL of:
/// 1. `resolvedKey == currentKey` — the loaded window belongs to the current
///    structural context. While a structural fetch owns the window
///    (`resolvedKey` is cleared in its synchronous prefix), refreshes stand
///    down; the resolve-flip re-keys the refresh task so an owed bump is
///    picked up the moment ownership returns — never dropped.
/// 2. `phase != .pending` — same ownership rule, belt-and-braces for the
///    window between the prefix and the key assignment.
/// 3. `refreshVersion != consumedVersion` — the bump has not already been
///    covered by a fetch. The structural task snapshots `refreshVersion`
///    immediately BEFORE its first-page fetch and assigns it on
///    resolve/failure, so a bump landing before the snapshot is (correctly)
///    treated as included in the fetched data, and a bump landing after it
///    stays owed.
///
/// `phase == .failed` deliberately passes (with matching key and an owed
/// version): a later bump must be able to heal a failed pane — the healing
/// contract the structural task documents.
nonisolated func shouldRunWindowRefresh(
  resolvedKey: String,
  currentKey: String,
  phase: FetchPhase,
  refreshVersion: Int,
  consumedVersion: Int
) -> Bool {
  guard resolvedKey == currentKey, phase != .pending else { return false }
  return refreshVersion != consumedVersion
}
