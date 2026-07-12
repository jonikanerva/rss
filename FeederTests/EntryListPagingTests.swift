import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - Render-window math (issue #151)

/// ux's threshold matrix, exercised AT the cap over pure DTO fixtures: the
/// slice is always a prefix of the canonical order, day groups never
/// duplicate their headers across a boundary, appends are monotone to the
/// true oldest row, and the restore-beyond-window math grows before scroll.
@MainActor
struct EntryListPagingTests {
  /// Rows with descending `publishedAt`, `perDay` rows per calendar day —
  /// the same shape the reader hands the grouping. Only the
  /// `PersistentIdentifier` needs a store (no public initializer).
  private static func makeRows(count: Int, perDay: Int) throws -> [EntryRowDTO] {
    let context = ModelContext(try DataWriterTestSupport.makeInMemoryContainer())
    let newest = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
    let dayLength: TimeInterval = 86_400
    return (0..<count).map { offset in
      let day = offset / perDay
      let slot = offset % perDay
      let publishedAt = newest.addingTimeInterval(
        -Double(day) * dayLength - Double(slot) * 60)
      let entry = Entry(
        feedbinEntryID: 8000 + offset, title: "Row \(offset)", author: nil,
        url: "https://example.com/\(offset)", content: nil, summary: nil,
        extractedContentURL: nil, publishedAt: publishedAt, createdAt: publishedAt)
      context.insert(entry)
      return EntryRowDTO(
        persistentID: entry.persistentModelID,
        feedbinEntryID: 8000 + offset,
        title: "Row \(offset)",
        formattedPublishedTime: "09.30",
        displayDomain: "example.com",
        excerpt: "Excerpt \(offset)",
        isRead: false,
        publishedAt: publishedAt,
        feedFeedbinID: 1,
        feedInitial: "E"
      )
    }
  }

  private static func flatIDs(_ sections: [EntryListSection]) -> [PersistentIdentifier] {
    sections.flatMap(\.rows).map(\.persistentID)
  }

  // MARK: - Slice shape

  @Test("Slice is the canonical prefix")
  func sliceIsCanonicalPrefix() throws {
    let rows = try Self.makeRows(count: 250, perDay: 40)
    let full = groupRowsByDay(rows)
    let slice = sectionsPrefix(full, limit: 100, triggerMargin: 20)
    #expect(slice.rowCount == 100)
    #expect(Self.flatIDs(slice.sections) == Array(rows.map(\.persistentID).prefix(100)))
    #expect(slice.lastRowID == rows[99].persistentID)
    // Trigger sits `margin` rows before the window end.
    #expect(slice.appendTriggerID == rows[80].persistentID)
  }

  @Test("Day group straddling the cap keeps its section id — no duplicate header")
  func boundaryInsideDayGroupKeepsSectionID() throws {
    // 40 rows/day ⇒ the cap at 100 lands inside day 3 (rows 80..<120).
    let rows = try Self.makeRows(count: 250, perDay: 40)
    let full = groupRowsByDay(rows)
    let slice = sectionsPrefix(full, limit: 100, triggerMargin: 20)
    let lastSliced = try #require(slice.sections.last)
    // The truncated section keeps the SAME start-of-day id and label as the
    // full section it slices — an append EXTENDS this Section in place, so
    // a day header can never appear twice.
    let fullCounterpart = try #require(full.first { $0.id == lastSliced.id })
    #expect(lastSliced.label == fullCounterpart.label)
    #expect(lastSliced.rows.count < fullCounterpart.rows.count)
    // Growing past the boundary keeps one section per day id.
    let grown = sectionsPrefix(full, limit: 300, triggerMargin: 20)
    #expect(grown.sections.map(\.id) == full.map(\.id))
  }

  // MARK: - Threshold matrix at the cap

  @Test("N == cap: no trigger, End reaches the true last row")
  func exactlyAtCapHasNoTrigger() throws {
    let rows = try Self.makeRows(count: 100, perDay: 40)
    let full = groupRowsByDay(rows)
    let slice = sectionsPrefix(full, limit: 100, triggerMargin: 20)
    #expect(slice.rowCount == 100)
    #expect(slice.appendTriggerID == nil)
    #expect(!hasMoreRows(renderLimit: 100, totalRows: 100))
    // The rendered last row IS the true oldest row.
    #expect(slice.lastRowID == rows.last?.persistentID)
  }

  @Test("N == cap + 1: one append reveals exactly the one older row")
  func capPlusOneAppendsExactlyOneRow() throws {
    let rows = try Self.makeRows(count: 101, perDay: 40)
    let full = groupRowsByDay(rows)
    let first = sectionsPrefix(full, limit: 100, triggerMargin: 20)
    #expect(first.rowCount == 100)
    #expect(first.appendTriggerID != nil)
    #expect(hasMoreRows(renderLimit: 100, totalRows: 101))
    let grownLimit = nextRenderLimit(current: 100, growthStep: 200)
    let grown = sectionsPrefix(full, limit: grownLimit, triggerMargin: 20)
    #expect(grown.rowCount == 101)
    #expect(grown.appendTriggerID == nil)
    #expect(grown.lastRowID == rows.last?.persistentID)
  }

  @Test("N >> cap: repeated growth walks monotonically to the oldest row")
  func repeatedGrowthReachesTheOldest() throws {
    let rows = try Self.makeRows(count: 750, perDay: 40)
    let full = groupRowsByDay(rows)
    var limit = 100
    var slice = sectionsPrefix(full, limit: limit, triggerMargin: 20)
    var steps = 0
    while hasMoreRows(renderLimit: limit, totalRows: rows.count) {
      let previousCount = slice.rowCount
      limit = nextRenderLimit(current: limit, growthStep: 200)
      slice = sectionsPrefix(full, limit: limit, triggerMargin: 20)
      #expect(slice.rowCount > previousCount)
      // Every grown slice extends the previous one — a strict prefix chain.
      steps += 1
      #expect(steps < 10, "growth must terminate")
    }
    #expect(slice.rowCount == 750)
    #expect(slice.lastRowID == rows.last?.persistentID)
    #expect(slice.appendTriggerID == nil)
  }

  @Test("Depth is retained across re-slices of a changed full result")
  func depthRetainedAcrossReslices() throws {
    // A refresh tick replaces the full result (top-insert) but the view
    // re-slices at the CURRENT renderLimit — the window never collapses.
    let rows = try Self.makeRows(count: 400, perDay: 40)
    let grownLimit = 300
    let topInserted = try Self.makeRows(count: 5, perDay: 5) + rows
    let reslice = sectionsPrefix(groupRowsByDay(topInserted), limit: grownLimit, triggerMargin: 20)
    #expect(reslice.rowCount == grownLimit)
  }

  // MARK: - Restore-beyond-window math

  @Test("Restore beyond the window grows the limit before scroll")
  func restoreBeyondWindowGrows() {
    #expect(renderLimitCovering(index: 150, margin: 20, current: 100) == 170)
  }

  @Test("Restore inside the window keeps the current limit")
  func restoreInsideWindowKeepsLimit() {
    #expect(renderLimitCovering(index: 40, margin: 20, current: 100) == 100)
  }

  @Test("Restore covering never renders less than the anchor row")
  func restoreCoveringIsTotalForDegenerateMargin() {
    #expect(renderLimitCovering(index: 150, margin: 0, current: 100) == 151)
  }

  // MARK: - Pure helper pins

  @Test("hasMoreRows is exact")
  func hasMoreRowsIsExact() {
    #expect(hasMoreRows(renderLimit: 99, totalRows: 100))
    #expect(!hasMoreRows(renderLimit: 100, totalRows: 100))
    #expect(!hasMoreRows(renderLimit: 300, totalRows: 100))
  }

  @Test("Trigger index clamps into the rendered range")
  func triggerIndexClamps() {
    #expect(appendTriggerIndex(renderedCount: 100, margin: 20) == 80)
    #expect(appendTriggerIndex(renderedCount: 10, margin: 20) == 0)
    #expect(appendTriggerIndex(renderedCount: 100, margin: 0) == 99)
    #expect(appendTriggerIndex(renderedCount: 0, margin: 20) == nil)
  }

  @Test("Empty and zero-limit inputs slice to empty")
  func degenerateInputsSliceToEmpty() throws {
    let rows = try Self.makeRows(count: 3, perDay: 3)
    let full = groupRowsByDay(rows)
    #expect(sectionsPrefix([], limit: 100, triggerMargin: 20) == .empty)
    #expect(sectionsPrefix(full, limit: 0, triggerMargin: 20) == .empty)
  }
}
