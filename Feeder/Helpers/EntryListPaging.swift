import Foundation
import SwiftData

// MARK: - Article-list render-window math (pure, issue #151)

/// The bounded render window sliced from the FULL fetched sections.
nonisolated struct EntryListRenderSlice: Sendable, Equatable {
  /// The first `limit` rows, day-grouped. The last section is truncated IN
  /// PLACE with its SAME start-of-day id, so a later append EXTENDS that
  /// `Section` — no duplicate day headers by construction.
  let sections: [EntryListSection]
  /// Rows in the slice — the `list-slice-apply` signpost payload.
  let rowCount: Int
  /// Last rendered row — the keyboard append trigger compares the new
  /// selection against this.
  let lastRowID: PersistentIdentifier?
  /// Row whose appearance requests the next append (`triggerMargin` rows
  /// before the window end); nil when the window already covers every row.
  let appendTriggerID: PersistentIdentifier?

  static let empty = EntryListRenderSlice(
    sections: [], rowCount: 0, lastRowID: nil, appendTriggerID: nil)
}

/// Slice the full day-grouped sections down to the first `limit` rows —
/// always a PREFIX of the canonical timestamp-desc order, never a reorder.
/// Pure and synchronous: the DTOs are value types sharing copy-on-write
/// storage with the full result, so slicing duplicates no row content.
nonisolated func sectionsPrefix(
  _ sections: [EntryListSection], limit: Int, triggerMargin: Int
) -> EntryListRenderSlice {
  guard limit > 0, !sections.isEmpty else { return .empty }
  var sliced: [EntryListSection] = []
  var flatRows: [EntryRowDTO] = []
  var remaining = limit
  for section in sections {
    if section.rows.count <= remaining {
      sliced.append(section)
      flatRows.append(contentsOf: section.rows)
      remaining -= section.rows.count
    } else {
      let prefix = Array(section.rows.prefix(remaining))
      sliced.append(EntryListSection(id: section.id, label: section.label, rows: prefix))
      flatRows.append(contentsOf: prefix)
      remaining = 0
    }
    if remaining == 0 { break }
  }
  let totalRows = sections.reduce(0) { $0 + $1.rows.count }
  let hasMore = hasMoreRows(renderLimit: limit, totalRows: totalRows)
  let triggerID: PersistentIdentifier? =
    if hasMore, let index = appendTriggerIndex(renderedCount: flatRows.count, margin: triggerMargin) {
      flatRows[index].persistentID
    } else {
      nil
    }
  return EntryListRenderSlice(
    sections: sliced,
    rowCount: flatRows.count,
    lastRowID: flatRows.last?.persistentID,
    appendTriggerID: triggerID
  )
}

/// EXACT more-rows check: the render window is smaller than the full result.
/// No estimation — the full result is already in memory, so `totalRows` is
/// the truth, and `renderLimit == totalRows` means End/Page-Down has reached
/// the true oldest row.
nonisolated func hasMoreRows(renderLimit: Int, totalRows: Int) -> Bool {
  renderLimit < totalRows
}

/// The next window size after an append request. Growth is monotonic within
/// one structural context; the structural reload resets to the initial cap.
nonisolated func nextRenderLimit(current: Int, growthStep: Int) -> Int {
  current + growthStep
}

/// Index of the rendered row whose appearance requests the next append —
/// `margin` rows before the window end, so the (synchronous, in-memory)
/// grow lands before the user reaches the bottom. Clamped into the valid
/// index range; nil for an empty window.
nonisolated func appendTriggerIndex(renderedCount: Int, margin: Int) -> Int? {
  guard renderedCount > 0 else { return nil }
  return min(renderedCount - 1, max(0, renderedCount - margin))
}

/// Window size that renders the row at 0-based `index` in the full result,
/// with `margin` rows of headroom below it — the restore-beyond-window grow
/// (issue #151): a restored selection / anchor deeper than the current
/// window grows the window BEFORE `scrollTo`, purely in memory. Never
/// shrinks the current window.
nonisolated func renderLimitCovering(index: Int, margin: Int, current: Int) -> Int {
  max(current, max(index + 1, index + margin))
}
