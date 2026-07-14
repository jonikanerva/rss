import Foundation
import SwiftData

// MARK: - Article-list keyset paging math (pure, issue #155)

/// The keyset cursor of the loaded window's bottom edge — the
/// `(publishedAt, feedbinEntryID)` sort key of the LAST loaded row. Always
/// DERIVED from the applied sections, never stored: the sections are the
/// single source of truth for what is loaded, so the cursor can never drift
/// from them. `nil` for an empty window (then the only valid fetch is a
/// first page).
nonisolated func entryListCursor(of sections: [EntryListSection]) -> EntryListCursor? {
  guard let lastRow = sections.last?.rows.last else { return nil }
  return EntryListCursor(
    publishedAt: lastRow.publishedAt, feedbinEntryID: lastRow.feedbinEntryID)
}

/// Index of the row whose appearance requests the next append — `margin`
/// rows before the window end, so the appended page usually lands before the
/// user reaches the bottom. Clamped into the valid index range for windows
/// smaller than the margin; nil for an empty window. (Revived from the
/// withdrawn PR #153, issue #155.)
nonisolated func appendTriggerIndex(fetchedCount: Int, margin: Int) -> Int? {
  guard fetchedCount > 0 else { return nil }
  return min(fetchedCount - 1, max(0, fetchedCount - margin))
}

/// Window size that covers a pinned row at 1-based `pinPosition` in the
/// sorted result — never smaller than the requested window. Chronology stays
/// continuous: the pin is covered by GROWING the first page, never by
/// unioning the pinned row out-of-band (which would render a timeline gap).
/// (Revived from the withdrawn PR #153, issue #155.)
nonisolated func effectiveRowLimit(requested: Int, pinPosition: Int) -> Int {
  max(requested, pinPosition)
}

/// The refresh-empty fallback rule (issue #155): an `atOrAbove` refresh that
/// resolves EMPTY (e.g. every loaded row left the filter after mark-all-read)
/// must not be applied directly — the pane would show a false "No Articles"
/// even though rows below the old window may still be eligible. The caller
/// runs ONE `firstPage` fetch instead and applies that.
nonisolated func refreshRequiresFirstPageFallback(
  window: EntryListWindow, result: EntryListFetchResult
) -> Bool {
  guard case .atOrAbove = window else { return false }
  return result.sections.isEmpty
}

// MARK: - Window append (section merge)

extension EntryListFetchResult {
  /// Merge an `after(cursor, limit:)` page onto this loaded window
  /// (issue #155). Pure tail extension by construction:
  /// - if the page's first section has the SAME id (start-of-day) as the
  ///   window's last section, that section is EXTENDED under its existing id
  ///   — no duplicate section identity, so the `List` diff is a pure tail
  ///   insertion and appends never run anchor-restore;
  /// - otherwise the page's sections concatenate after the window's.
  ///
  /// Aggregates union from the rows actually appended; `hasMore` adopts the
  /// page's (the page's bottom edge is the new window bottom).
  ///
  /// Dedupe (belt-and-braces for the `persistEntries` immutability
  /// invariant): any page row whose `feedbinEntryID` already exists in the
  /// window is dropped, so a future violation of "cursor keys of persisted
  /// rows never mutate" degrades to a skipped row instead of a duplicated
  /// one. Exact tiling still comes from the invariant itself.
  func appending(_ page: EntryListFetchResult) -> EntryListFetchResult {
    let existingIDs = Set(sections.lazy.flatMap(\.rows).map(\.feedbinEntryID))
    let dedupedSections: [EntryListSection] = page.sections.compactMap { section in
      let rows = section.rows.filter { !existingIDs.contains($0.feedbinEntryID) }
      guard !rows.isEmpty else { return nil }
      return EntryListSection(id: section.id, label: section.label, rows: rows)
    }
    guard !dedupedSections.isEmpty else {
      return EntryListFetchResult(
        sections: sections,
        allEntryIDs: allEntryIDs,
        distinctFeedIDs: distinctFeedIDs,
        renderedUnreadFeedbinEntryIDs: renderedUnreadFeedbinEntryIDs,
        hasMore: page.hasMore
      )
    }
    var mergedSections = sections
    var remainder = dedupedSections[...]
    if let lastSection = mergedSections.last, let firstPageSection = remainder.first,
      lastSection.id == firstPageSection.id
    {
      mergedSections[mergedSections.count - 1] = EntryListSection(
        id: lastSection.id, label: lastSection.label,
        rows: lastSection.rows + firstPageSection.rows)
      remainder = remainder.dropFirst()
    }
    mergedSections.append(contentsOf: remainder)
    let appendedRows = dedupedSections.flatMap(\.rows)
    return EntryListFetchResult(
      sections: mergedSections,
      allEntryIDs: allEntryIDs + appendedRows.map(\.persistentID),
      distinctFeedIDs: distinctFeedIDs.union(appendedRows.compactMap(\.feedFeedbinID)),
      renderedUnreadFeedbinEntryIDs: renderedUnreadFeedbinEntryIDs.union(
        appendedRows.lazy.filter { !$0.isRead }.map(\.feedbinEntryID)),
      hasMore: page.hasMore
    )
  }
}
