import Foundation

// MARK: - Fetch Phase

/// Lifecycle of the article-list background fetch for the current structural
/// context. A tagged union, so "the fetch has not resolved yet" stays
/// distinguishable from "the fetch resolved empty": that distinction is what
/// makes a false "No Articles" on a populated category unreachable.
nonisolated enum FetchPhase: Sendable, Equatable {
  /// A structural fetch is in flight; nothing is known about the new context yet.
  case pending
  /// The most recent structural or refresh fetch applied its result.
  case resolved
  /// The structural fetch failed with a store error. There is no retry: the
  /// shared coordinator blocks rather than throws under contention, so a throw
  /// is almost certainly persistent. Any later successful fetch heals it.
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
}

/// Pure precedence rule for the article-list pane, most binding first:
/// 1. `hasSections` → `.list`. Fetched rows always render, whatever the phase
///    or the sync error says: continuity over blankness.
/// 2. `.pending` → `.blank`. An unresolved fetch asserts nothing, so any
///    empty-family pane here would claim something about an unread context.
/// 3. `.failed` → `.error`. A store read failure outranks the sync errors:
///    "couldn't load" must not masquerade as "offline" or "empty".
/// 4. `isAuthFailed`, then `isOffline`, then `.noArticles`.
///
/// The signature carries no engine flags on purpose. A resolved-empty fetch
/// means the store holds no rows for this context now, and the drain channel
/// re-fetches as classification lands rows, so the pane populates live.
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

/// Pure scheduling gate for the whole-window refresh channel. It lives here,
/// not with the paging math, because it reads `FetchPhase` and is fetch
/// lifecycle logic.
///
/// A refresh may run only when all three hold:
/// 1. The loaded window belongs to the current structural context. While a
///    structural fetch owns the window, refreshes stand down, and the resolve
///    flip re-keys the refresh task so an owed bump is never dropped.
/// 2. The phase is not pending, which covers the window between the structural
///    prefix and the key assignment.
/// 3. The bump is not already covered by a fetch.
///
/// A failed phase passes on purpose: a later bump must be able to heal a failed
/// pane.
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
