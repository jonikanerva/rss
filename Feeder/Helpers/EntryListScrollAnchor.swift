import Foundation
import SwiftData

// MARK: - Article-list scroll anchor math (pure)

/// One on-screen data row before a refresh, in table coordinates.
nonisolated struct ScrollAnchorCandidate: Sendable, Equatable {
  let id: PersistentIdentifier
  let tableRow: Int
  let documentMinY: CGFloat
}

/// The frame of one table row that is on screen.
nonisolated struct ScrollAnchorRowFrame: Sendable, Equatable {
  let tableRow: Int
  let minY: CGFloat
  let maxY: CGFloat
}

/// The row that the compensation keeps in place after the update.
/// `newTableRow` counts header rows.
nonisolated struct ScrollAnchorTarget: Sendable, Equatable {
  let newTableRow: Int
  let oldDocumentMinY: CGFloat
  let oldRowCount: Int
  let expectedRowCount: Int
}

/// The table rows of the article list: one header row per section, then the
/// rows of the section.
nonisolated enum EntryListTableLayout {
  static func rowCount(of sections: [EntryListSection]) -> Int {
    sections.reduce(0) { $0 + 1 + $1.rows.count }
  }

  /// `nil` for a header row and for a row outside the sections.
  static func entryID(atTableRow row: Int, in sections: [EntryListSection]) -> PersistentIdentifier? {
    guard row >= 0 else { return nil }
    var sectionStart = 0
    for section in sections {
      let sectionEnd = sectionStart + 1 + section.rows.count
      if row < sectionEnd {
        return row == sectionStart ? nil : section.rows[row - sectionStart - 1].persistentID
      }
      sectionStart = sectionEnd
    }
    return nil
  }
}

nonisolated enum EntryListScrollAnchor {
  static let maxCandidates = 8

  /// The on-screen data rows, top first, at most `maxCandidates`. A row counts
  /// when more than half a point of it shows below `origin`.
  static func candidates(
    visibleRows: [ScrollAnchorRowFrame], origin: CGFloat, sections: [EntryListSection]
  ) -> [ScrollAnchorCandidate] {
    var result: [ScrollAnchorCandidate] = []
    for row in visibleRows where row.maxY > origin + 0.5 {
      guard let id = EntryListTableLayout.entryID(atTableRow: row.tableRow, in: sections) else { continue }
      result.append(ScrollAnchorCandidate(id: id, tableRow: row.tableRow, documentMinY: row.minY))
      if result.count == maxCandidates { break }
    }
    return result
  }

  /// The first candidate that is still in `newSections`, mapped to its new
  /// table row. `nil` when no candidate survives, or when the table rows from
  /// row 0 through that candidate are the same in both layouts: no row above
  /// it moved, so there is nothing to compensate.
  static func target(
    candidates: [ScrollAnchorCandidate],
    oldSections: [EntryListSection], newSections: [EntryListSection]
  ) -> ScrollAnchorTarget? {
    guard !candidates.isEmpty else { return nil }
    let rankByID = Dictionary(
      candidates.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    var best: (rank: Int, tableRow: Int)?
    var tableRow = 0
    scan: for section in newSections {
      tableRow += 1
      for row in section.rows {
        if let rank = rankByID[row.persistentID], rank < (best?.rank ?? Int.max) {
          best = (rank, tableRow)
          if rank == 0 { break scan }
        }
        tableRow += 1
      }
    }
    guard let best else { return nil }
    let anchor = candidates[best.rank]
    guard
      !rowsMatch(
        through: anchor.id, oldRow: anchor.tableRow, newRow: best.tableRow,
        oldSections: oldSections, newSections: newSections)
    else { return nil }
    return ScrollAnchorTarget(
      newTableRow: best.tableRow,
      oldDocumentMinY: anchor.documentMinY,
      oldRowCount: EntryListTableLayout.rowCount(of: oldSections),
      expectedRowCount: EntryListTableLayout.rowCount(of: newSections))
  }

  /// The new clip origin: the anchor keeps its offset from the top edge,
  /// clamped to the scrollable range.
  static func clipOrigin(
    newAnchorMinY: CGFloat, oldAnchorMinY: CGFloat, originBeforeUpdate: CGFloat,
    documentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat
  ) -> CGFloat {
    let offset = oldAnchorMinY - originBeforeUpdate
    let lowest = -topInset
    let highest = max(lowest, documentHeight - viewportHeight + bottomInset)
    return min(max(newAnchorMinY - offset, lowest), highest)
  }

  /// Whether the anchor keeps its table row and every header and entry above
  /// it is the same, in the same order, in both layouts.
  private static func rowsMatch(
    through id: PersistentIdentifier, oldRow: Int, newRow: Int,
    oldSections: [EntryListSection], newSections: [EntryListSection]
  ) -> Bool {
    guard oldRow == newRow else { return false }
    var oldRows = TableRowKeys(sections: oldSections)
    var newRows = TableRowKeys(sections: newSections)
    while let oldKey = oldRows.next() {
      guard newRows.next() == oldKey else { return false }
      if oldKey == .entry(id) { return true }
    }
    return false
  }
}

/// One table row of the article list: a section header or an entry.
nonisolated private enum TableRowKey: Equatable {
  case header(Date)
  case entry(PersistentIdentifier)
}

/// The table rows of `sections` in table order, without building an array.
nonisolated private struct TableRowKeys: IteratorProtocol {
  let sections: [EntryListSection]
  var sectionIndex = 0
  var rowIndex: Int?

  mutating func next() -> TableRowKey? {
    while sectionIndex < sections.count {
      let section = sections[sectionIndex]
      guard let index = rowIndex else {
        rowIndex = 0
        return .header(section.id)
      }
      if index < section.rows.count {
        rowIndex = index + 1
        return .entry(section.rows[index].persistentID)
      }
      sectionIndex += 1
      rowIndex = nil
    }
    return nil
  }
}
