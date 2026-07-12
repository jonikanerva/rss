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
  /// The structural fetch and its single bounded retry both failed with a
  /// store error. Healed by any later successful refresh reload.
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
  /// Empty and the fetch itself failed twice — store error, not sync state.
  case error
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
