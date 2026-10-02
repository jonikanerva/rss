import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import Feeder

/// Offscreen checks of `ScrollAnchorKeeper` on the article-list shape, with the
/// probe in each section header. Each test calls `prepareForUpdate(from:to:)`,
/// assigns the new sections, and reads the backing table through public API.
/// Each host window opens far offscreen, at the origin (-6000, -6000).
@Suite("Entry list scroll anchor layout", .serialized)
@MainActor
struct EntryListScrollAnchorLayoutTests {
  @Test("one row inserted above the middle of the list keeps the visible rows in place")
  func insertAboveMiddleKeepsRows() async throws {
    let host = try await Host.make()
    defer { host.close() }
    try await host.scrollToMiddle()
    try await host.expectRowsKept(afterInserting: 1)
  }

  @Test("one row inserted at the top of the list keeps the visible rows in place")
  func insertAtTopKeepsRows() async throws {
    let host = try await Host.make()
    defer { host.close() }
    try await host.expectRowsKept(afterInserting: 1)
  }

  @Test("a burst taller than the viewport keeps the visible rows in place")
  func burstAboveMiddleKeepsRows() async throws {
    let host = try await Host.make()
    defer { host.close() }
    try await host.scrollToMiddle()
    try await host.expectRowsKept(afterInserting: 8)
  }
}

// MARK: - Host

@Observable
@MainActor
private final class ScrollAnchorLayoutModel {
  var sections: [EntryListSection] = []
}

private struct ScrollAnchorLayoutList: View {
  @Bindable
  var model: ScrollAnchorLayoutModel
  let settings: AppFontSettings
  let keeper: ScrollAnchorKeeper

  var body: some View {
    List {
      ForEach(model.sections) { section in
        Section {
          ForEach(section.rows) { row in
            EntryRowView(row: row, faviconImage: nil)
              .tag(row.persistentID)
              .modifier(EntryListRowModifiers())
          }
        } header: {
          Text(section.label)
            .font(settings.sectionLabel)
            .foregroundStyle(.tertiary)
            .textCase(nil)
            .background {
              ScrollAnchorProbe(keeper: keeper)
                .accessibilityHidden(true)
            }
        }
      }
    }
    .modifier(EntryListModifiers(rowHeight: settings.entryRowHeight))
    .environment(settings)
  }
}

@MainActor
private final class Host {
  private static let dayZero = Date(timeIntervalSince1970: 1_750_032_000)

  let settings: AppFontSettings
  private let isolatedDefaults: IsolatedDefaults
  let model: ScrollAnchorLayoutModel
  let keeper: ScrollAnchorKeeper
  let hosting: NSHostingView<ScrollAnchorLayoutList>
  let window: NSWindow
  private var spareIDs: ArraySlice<PersistentIdentifier>
  private var nextNumber = 1

  private init(isolatedDefaults: IsolatedDefaults, ids: [PersistentIdentifier]) {
    let settings = AppFontSettings(textSize: .medium, userDefaults: isolatedDefaults.defaults)
    let model = ScrollAnchorLayoutModel()
    let keeper = ScrollAnchorKeeper()
    self.isolatedDefaults = isolatedDefaults
    self.settings = settings
    self.model = model
    self.keeper = keeper
    spareIDs = ids[...]
    hosting = NSHostingView(rootView: ScrollAnchorLayoutList(model: model, settings: settings, keeper: keeper))
    hosting.frame = NSRect(x: -6000, y: -6000, width: 320, height: 600)
    window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
  }

  /// Three days of 40, 30, and 30 rows, settled at the top.
  static func make() async throws -> Host {
    let host = Host(
      isolatedDefaults: try IsolatedDefaults("EntryListScrollAnchorLayout"),
      ids: PreviewSupport.mintEntryIdentifiers(count: 110))
    host.model.sections = [
      host.section(day: 0, rows: try host.makeRows(40)),
      host.section(day: 1, rows: try host.makeRows(30)),
      host.section(day: 2, rows: try host.makeRows(30)),
    ]
    host.window.orderFrontRegardless()
    _ = try await host.settle(expectedRows: EntryListTableLayout.rowCount(of: host.model.sections), anchorRow: 0)
    return host
  }

  func close() {
    window.orderOut(nil)
  }

  // MARK: Data

  private func makeRows(_ count: Int) throws -> [EntryRowDTO] {
    try (0..<count).map { _ in
      let spare = spareIDs.popFirst()
      let id = try #require(spare, "out of minted identifiers")
      let number = nextNumber
      nextNumber += 1
      return EntryRowDTO(
        persistentID: id,
        feedbinEntryID: number,
        title: "Row \(number)",
        url: "https://example.com/\(number)",
        formattedPublishedTime: "09.30",
        displayDomain: "example.com",
        excerpt: "A short excerpt that fills the summary lines of the row with plain words only.",
        isRead: false,
        publishedAt: Date(timeIntervalSince1970: 1_750_000_000),
        feedFeedbinID: 1,
        feedInitial: "M"
      )
    }
  }

  private func section(day: Int, rows: [EntryRowDTO]) -> EntryListSection {
    EntryListSection(id: Self.dayZero.addingTimeInterval(-Double(day) * 86_400), label: "Day \(day)", rows: rows)
  }

  // MARK: Table

  private func table() throws -> NSTableView {
    try #require(Self.findTableView(in: hosting), "no table under the hosting view")
  }

  private func clip() throws -> NSClipView {
    try #require(try table().enclosingScrollView?.contentView, "no clip view around the table")
  }

  private static func findTableView(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
      if let table = findTableView(in: subview) { return table }
    }
    return nil
  }

  /// Polls until the table has `expectedRows` rows, and the clip origin and
  /// the frame of `anchorRow` agree for ten samples in a row, with a 5 ms
  /// sleep between polls. Fails the test after 2 s. Returns the origin.
  private func settle(expectedRows: Int, anchorRow: Int) async throws -> CGFloat {
    let deadline = ContinuousClock.now + .seconds(2)
    var stableSamples = 0
    var previous: (origin: CGFloat, rect: NSRect)?
    while true {
      hosting.layoutSubtreeIfNeeded()
      if let table = Self.findTableView(in: hosting), let clip = table.enclosingScrollView?.contentView,
        table.numberOfRows == expectedRows
      {
        let sample = (origin: clip.bounds.origin.y, rect: table.rect(ofRow: anchorRow))
        stableSamples = previous.map { $0 == sample } == true ? stableSamples + 1 : 1
        previous = sample
        if stableSamples == 10 { return sample.origin }
      } else {
        stableSamples = 0
        previous = nil
      }
      try #require(ContinuousClock.now < deadline, "the table did not settle at \(expectedRows) rows within 2 s")
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: Cases

  /// Scrolls so that table row 60 shows only in part at the top edge.
  func scrollToMiddle() async throws {
    let table = try table()
    let clip = try clip()
    clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 60).minY + 0.4 * settings.entryRowHeight))
    table.enclosingScrollView?.reflectScrolledClipView(clip)
    _ = try await settle(expectedRows: table.numberOfRows, anchorRow: 60)
  }

  /// Inserts `count` rows at the start of the first day and expects the first
  /// fully visible data row to keep its offset from the top edge, although
  /// its position in the table moved.
  func expectRowsKept(afterInserting count: Int) async throws {
    let table = try table()
    let originBefore = try clip().bounds.origin.y
    let old = model.sections
    let visible = table.rows(in: try clip().documentVisibleRect)
    let anchorRow = try #require(
      (visible.location..<(visible.location + visible.length)).first { row in
        EntryListTableLayout.entryID(atTableRow: row, in: old) != nil && table.rect(ofRow: row).minY >= originBefore
      },
      "no fully visible data row")
    let anchorID = try #require(EntryListTableLayout.entryID(atTableRow: anchorRow, in: old))
    let anchorMinYBefore = table.rect(ofRow: anchorRow).minY
    let offsetBefore = anchorMinYBefore - originBefore

    let new =
      [EntryListSection(id: old[0].id, label: old[0].label, rows: try makeRows(count) + old[0].rows)]
      + old.dropFirst()
    let expectedRows = EntryListTableLayout.rowCount(of: new)
    let newAnchorRow = try #require(
      (0..<expectedRows).first { EntryListTableLayout.entryID(atTableRow: $0, in: new) == anchorID })
    keeper.prepareForUpdate(from: old, to: new)
    model.sections = new

    let originAfter = try await settle(expectedRows: expectedRows, anchorRow: newAnchorRow)
    let anchorMinYAfter = table.rect(ofRow: newAnchorRow).minY
    #expect(table.numberOfRows == expectedRows)
    #expect(
      abs(anchorMinYAfter - anchorMinYBefore) > 0.5,
      "the rows above the anchor did not move: \(anchorMinYBefore) -> \(anchorMinYAfter)")
    #expect(
      abs((anchorMinYAfter - originAfter) - offsetBefore) <= 0.5,
      "anchor offset \(offsetBefore) -> \(anchorMinYAfter - originAfter), origin \(originBefore) -> \(originAfter)")
  }
}
