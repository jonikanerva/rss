import Foundation
import SwiftData

// MARK: - Article-list keyset paging math (pure)

/// The keyset cursor of the loaded window's bottom edge: the sort key of the
/// last loaded row. Always derived from the applied sections, never stored, so
/// the cursor cannot drift from what is loaded. `nil` for an empty window,
/// where the only valid fetch is a first page.
nonisolated func entryListCursor(of sections: [EntryListSection]) -> EntryListCursor? {
  guard let lastRow = sections.last?.rows.last else { return nil }
  return EntryListCursor(
    publishedAt: lastRow.publishedAt, feedbinEntryID: lastRow.feedbinEntryID)
}

/// Index of the row whose appearance requests the next append: `margin` rows
/// before the window end, so the page usually lands before the user reaches the
/// bottom. Clamped for a window smaller than the margin, `nil` for an empty one.
nonisolated func appendTriggerIndex(fetchedCount: Int, margin: Int) -> Int? {
  guard fetchedCount > 0 else { return nil }
  return min(fetchedCount - 1, max(0, fetchedCount - margin))
}

/// Window size that covers a pinned row at 1-based `pinPosition`, never
/// smaller than the requested window. Cover the pin by growing the first page,
/// never by unioning the pinned row out-of-band: that renders a timeline gap.
nonisolated func effectiveRowLimit(requested: Int, pinPosition: Int) -> Int {
  max(requested, pinPosition)
}

/// The refresh-empty fallback rule. An `atOrAbove` refresh that resolves empty
/// must not be applied directly: the pane would claim "No Articles" while rows
/// below the window are still eligible. The caller runs one `firstPage` fetch
/// and applies that instead.
nonisolated func refreshRequiresFirstPageFallback(
  window: EntryListWindow, result: EntryListFetchResult
) -> Bool {
  guard case .atOrAbove = window else { return false }
  return result.sections.isEmpty
}

// MARK: - Window append (section merge)

extension EntryListFetchResult {
  /// Merge an `after(cursor, limit:)` page onto this loaded window, as a pure
  /// tail extension. A page section sharing the window's last section id
  /// extends that section under its existing id, so the `List` diff stays a
  /// tail insertion and no append restores an anchor; any other section
  /// concatenates after it. The aggregates union from the appended rows, and
  /// `hasMore` adopts the page's.
  ///
  /// A page row whose `feedbinEntryID` already exists in the window is dropped,
  /// so a violation of the `persistEntries` immutability invariant degrades to
  /// a skipped row instead of a duplicate. Exact tiling still comes from that
  /// invariant.
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
