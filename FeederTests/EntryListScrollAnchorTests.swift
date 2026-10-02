import Foundation
import SwiftData
import Testing

@testable import Feeder

/// The pure scroll-anchor math: the table layout of the sections, the
/// on-screen candidates, the target after an update, and the compensated clip
/// origin.
@Suite("Entry list scroll anchor")
@MainActor
struct EntryListScrollAnchorTests {
  private static let dayZero = Date(timeIntervalSince1970: 1_750_032_000)

  // MARK: - Fixtures

  private static func row(_ id: PersistentIdentifier, number: Int, isRead: Bool = false) -> EntryRowDTO {
    EntryRowDTO(
      persistentID: id,
      feedbinEntryID: number,
      title: "Row \(number)",
      url: "https://example.com/\(number)",
      formattedPublishedTime: "09.30",
      displayDomain: "example.com",
      excerpt: "Excerpt",
      isRead: isRead,
      publishedAt: Date(timeIntervalSince1970: 1_750_000_000),
      feedFeedbinID: 1,
      feedInitial: "M"
    )
  }

  private static func section(day: Int, _ rows: [EntryRowDTO]) -> EntryListSection {
    EntryListSection(id: dayZero.addingTimeInterval(-Double(day) * 86_400), label: "Day \(day)", rows: rows)
  }

  /// Rows for `ids`, numbered from `first`.
  private static func rows(_ ids: ArraySlice<PersistentIdentifier>, first: Int = 1) -> [EntryRowDTO] {
    ids.enumerated().map { row($0.element, number: first + $0.offset) }
  }

  /// Three days of 40, 30, and 30 rows from the first 100 ids. Table rows: the
  /// Day 0 header at 0, the Day 1 header at 41, the Day 2 header at 72.
  private static func threeDays(_ ids: [PersistentIdentifier]) -> [EntryListSection] {
    [
      section(day: 0, rows(ids[0..<40])),
      section(day: 1, rows(ids[40..<70], first: 41)),
      section(day: 2, rows(ids[70..<100], first: 71)),
    ]
  }

  private static func inserting(
    _ rows: [EntryRowDTO], intoSection index: Int, of sections: [EntryListSection]
  ) -> [EntryListSection] {
    var result = sections
    let target = sections[index]
    result[index] = EntryListSection(id: target.id, label: target.label, rows: rows + target.rows)
    return result
  }

  private static func removing(_ ids: Set<PersistentIdentifier>, from sections: [EntryListSection]) -> [EntryListSection] {
    sections.map { section in
      EntryListSection(id: section.id, label: section.label, rows: section.rows.filter { !ids.contains($0.persistentID) })
    }
  }

  /// Candidates for the on-screen table rows `tableRows`, with a 109-pt row
  /// pitch from document 0.
  private static func candidates(tableRows: [Int], in sections: [EntryListSection]) -> [ScrollAnchorCandidate] {
    tableRows.compactMap { tableRow in
      EntryListTableLayout.entryID(atTableRow: tableRow, in: sections).map {
        ScrollAnchorCandidate(id: $0, tableRow: tableRow, documentMinY: CGFloat(tableRow) * 109)
      }
    }
  }

  // MARK: - Table layout

  @Test("the row count is one header row per section plus the rows")
  func rowCountCountsHeaderRows() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 6)
    let sections = [
      Self.section(day: 0, Self.rows(ids[0..<2])),
      Self.section(day: 1, Self.rows(ids[2..<5])),
      Self.section(day: 2, Self.rows(ids[5..<6])),
    ]
    #expect(EntryListTableLayout.rowCount(of: sections) == 9)
    #expect(EntryListTableLayout.rowCount(of: []) == 0)
  }

  @Test("a header row and a row outside the sections map to no entry")
  func entryIDSkipsHeaderRows() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 6)
    let sections = [
      Self.section(day: 0, Self.rows(ids[0..<2])),
      Self.section(day: 1, Self.rows(ids[2..<5])),
      Self.section(day: 2, Self.rows(ids[5..<6])),
    ]
    let expected: [PersistentIdentifier?] = [nil, ids[0], ids[1], nil, ids[2], ids[3], ids[4], nil, ids[5]]
    for (tableRow, id) in expected.enumerated() {
      #expect(EntryListTableLayout.entryID(atTableRow: tableRow, in: sections) == id, "table row \(tableRow)")
    }
    #expect(EntryListTableLayout.entryID(atTableRow: 9, in: sections) == nil)
    #expect(EntryListTableLayout.entryID(atTableRow: -1, in: sections) == nil)
  }

  // MARK: - Candidates

  @Test("candidates skip header rows, keep a partly visible top row, and keep the top-first order")
  func candidatesSkipHeadersAndKeepPartialTopRow() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 6)
    let sections = [
      Self.section(day: 0, Self.rows(ids[0..<2])),
      Self.section(day: 1, Self.rows(ids[2..<6])),
    ]
    let frames = [
      ScrollAnchorRowFrame(tableRow: 1, minY: 0, maxY: 100.5),
      ScrollAnchorRowFrame(tableRow: 2, minY: 100.5, maxY: 209.5),
      ScrollAnchorRowFrame(tableRow: 3, minY: 209.5, maxY: 247.5),
      ScrollAnchorRowFrame(tableRow: 4, minY: 247.5, maxY: 356.5),
    ]
    let result = EntryListScrollAnchor.candidates(visibleRows: frames, origin: 150, sections: sections)
    #expect(
      result == [
        ScrollAnchorCandidate(id: ids[1], tableRow: 2, documentMinY: 100.5),
        ScrollAnchorCandidate(id: ids[2], tableRow: 4, documentMinY: 247.5),
      ])
  }

  @Test("a row with no more than half a point below the origin is not a candidate")
  func candidatesDropRowsAboveTheOrigin() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 3)
    let sections = [Self.section(day: 0, Self.rows(ids[0..<3]))]
    let frames = [
      ScrollAnchorRowFrame(tableRow: 1, minY: 0, maxY: 100.5),
      ScrollAnchorRowFrame(tableRow: 2, minY: 100.5, maxY: 209.5),
    ]
    let result = EntryListScrollAnchor.candidates(visibleRows: frames, origin: 100, sections: sections)
    #expect(result.map(\.tableRow) == [2])
  }

  @Test("500 on-screen rows give at most maxCandidates candidates, from the top")
  func candidatesStayWithinTheBound() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 500)
    let sections = [Self.section(day: 0, Self.rows(ids[0..<500]))]
    let frames = (1...500).map { ScrollAnchorRowFrame(tableRow: $0, minY: CGFloat($0) * 109, maxY: CGFloat($0 + 1) * 109) }
    let result = EntryListScrollAnchor.candidates(visibleRows: frames, origin: 0, sections: sections)
    #expect(result.count == EntryListScrollAnchor.maxCandidates)
    #expect(result.map(\.tableRow) == Array(1...EntryListScrollAnchor.maxCandidates))
  }

  // MARK: - Target

  @Test("rows inserted at the start of the first day move the anchor down by their count")
  func targetFollowsSameDayInsert() throws {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 102)
    let old = Self.threeDays(ids)
    let new = Self.inserting(Self.rows(ids[100..<102], first: 101), intoSection: 0, of: old)
    let candidates = Self.candidates(tableRows: [60, 61, 62], in: old)
    let target = try #require(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new))
    #expect(target.newTableRow == 62)
    #expect(target.oldDocumentMinY == CGFloat(60 * 109))
    #expect(target.oldRowCount == 103)
    #expect(target.expectedRowCount == EntryListTableLayout.rowCount(of: new))
    #expect(target.expectedRowCount == 105)
  }

  @Test("a new day section above moves the anchor down by its rows and its header row")
  func targetFollowsNewDaySection() throws {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 103)
    let old = Self.threeDays(ids)
    let new = [Self.section(day: -1, Self.rows(ids[100..<103], first: 101))] + old
    let candidates = Self.candidates(tableRows: [60], in: old)
    let target = try #require(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new))
    #expect(target.newTableRow == 64)
  }

  @Test("rows removed above move the anchor up by their count")
  func targetFollowsRemovalAbove() throws {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 100)
    let old = Self.threeDays(ids)
    let new = Self.removing([ids[3], ids[4]], from: old)
    let candidates = Self.candidates(tableRows: [60], in: old)
    let target = try #require(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new))
    #expect(target.newTableRow == 58)
  }

  @Test("a removed anchor hands over to the next surviving candidate and its own offset")
  func targetFallsBackToNextCandidate() throws {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 101)
    let old = Self.threeDays(ids)
    let anchorID = try #require(EntryListTableLayout.entryID(atTableRow: 60, in: old))
    let new = Self.inserting([Self.row(ids[100], number: 101)], intoSection: 0, of: Self.removing([anchorID], from: old))
    let candidates = Self.candidates(tableRows: [60, 61], in: old)
    let target = try #require(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new))
    #expect(target.newTableRow == 61)
    #expect(target.oldDocumentMinY == CGFloat(61 * 109))
  }

  @Test("no surviving candidate and no candidate at all give no target")
  func targetIsNilWithoutSurvivor() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 101)
    let old = Self.threeDays(ids)
    let candidates = Self.candidates(tableRows: [60, 61], in: old)
    let new = Self.removing(Set(candidates.map(\.id)), from: old)
    #expect(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new) == nil)
    let inserted = Self.inserting([Self.row(ids[100], number: 101)], intoSection: 0, of: old)
    #expect(EntryListScrollAnchor.target(candidates: [], oldSections: old, newSections: inserted) == nil)
  }

  @Test("an in-place refresh with the same rows in the same order gives no target")
  func targetIsNilForInPlaceRefresh() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 100)
    let old = Self.threeDays(ids)
    let new = old.map { section in
      EntryListSection(
        id: section.id, label: section.label,
        rows: section.rows.map { Self.row($0.persistentID, number: $0.feedbinEntryID, isRead: true) })
    }
    let candidates = Self.candidates(tableRows: [60, 61], in: old)
    #expect(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new) == nil)
  }

  @Test("rows removed below the anchor or appended after it give no target")
  func targetIsNilForChangesBelow() {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 110)
    let old = Self.threeDays(ids)
    let candidates = Self.candidates(tableRows: [60, 61], in: old)
    let removedBelow = Self.removing([ids[98], ids[99]], from: old)
    #expect(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: removedBelow) == nil)
    let appended = old + [Self.section(day: 3, Self.rows(ids[100..<110], first: 101))]
    #expect(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: appended) == nil)
  }

  @Test("a row removed above and a row inserted above keep the anchor row but still give a target")
  func targetForSwapAbove() throws {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 101)
    let old = Self.threeDays(ids)
    let new = Self.inserting([Self.row(ids[100], number: 101)], intoSection: 0, of: Self.removing([ids[10]], from: old))
    let candidates = Self.candidates(tableRows: [60], in: old)
    let target = try #require(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new))
    #expect(target.newTableRow == 60)
  }

  @Test("two rows above that swap places give a target")
  func targetForReorderAbove() throws {
    let ids = PreviewSupport.mintEntryIdentifiers(count: 100)
    let old = Self.threeDays(ids)
    var dayZeroRows = old[0].rows
    dayZeroRows.swapAt(5, 6)
    var new = old
    new[0] = EntryListSection(id: old[0].id, label: old[0].label, rows: dayZeroRows)
    let candidates = Self.candidates(tableRows: [60], in: old)
    let target = try #require(EntryListScrollAnchor.target(candidates: candidates, oldSections: old, newSections: new))
    #expect(target.newTableRow == 60)
  }

  // MARK: - Clip origin

  @Test("the anchor keeps its offset from the top edge")
  func clipOriginKeepsOffset() {
    let origin = EntryListScrollAnchor.clipOrigin(
      newAnchorMinY: 6_558.25, oldAnchorMinY: 6_451.60, originBeforeUpdate: 6_386.20,
      documentHeight: 11_150.65, viewportHeight: 600, topInset: 0, bottomInset: 0)
    #expect(abs(origin - 6_492.85) < 0.001)
  }

  @Test("a scroll before the update keeps the anchor at its offset from the new origin")
  func clipOriginFollowsScrollBeforeUpdate() {
    let origin = EntryListScrollAnchor.clipOrigin(
      newAnchorMinY: 1_106.65, oldAnchorMinY: 1_000, originBeforeUpdate: 1_100,
      documentHeight: 11_000, viewportHeight: 600, topInset: 0, bottomInset: 0)
    #expect(abs(origin - 1_206.65) < 0.001)
  }

  @Test("the origin clamps to the top inset", arguments: [CGFloat(0), 52])
  func clipOriginClampsAtTop(topInset: CGFloat) {
    let origin = EntryListScrollAnchor.clipOrigin(
      newAnchorMinY: 10, oldAnchorMinY: 200, originBeforeUpdate: 0,
      documentHeight: 11_000, viewportHeight: 600, topInset: topInset, bottomInset: 0)
    #expect(origin == -topInset)
  }

  @Test("the origin clamps to the end of the document")
  func clipOriginClampsAtBottom() {
    let origin = EntryListScrollAnchor.clipOrigin(
      newAnchorMinY: 10_900, oldAnchorMinY: 500, originBeforeUpdate: 400,
      documentHeight: 11_000, viewportHeight: 600, topInset: 0, bottomInset: 20)
    #expect(origin == 10_420)
  }

  @Test("a document shorter than the viewport keeps the origin at the top inset")
  func clipOriginForShortDocument() {
    let origin = EntryListScrollAnchor.clipOrigin(
      newAnchorMinY: 300, oldAnchorMinY: 100, originBeforeUpdate: 0,
      documentHeight: 400, viewportHeight: 600, topInset: 52, bottomInset: 0)
    #expect(origin == -52)
  }
}
