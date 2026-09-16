import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import Feeder

/// Headless geometry check for the row-height floor (issue #170). Hosts the
/// same `List` shape `EntryListView` renders — inset style, hidden
/// separators, explicit row insets, `defaultMinListRowHeight` floor — in an
/// offscreen `NSHostingView`, then reads the backing `NSTableView` through
/// public API. Two invariants:
///
/// 1. The table's fallback row height (`NSTableView.rowHeight`) equals the
///    floor. This is the value the macOS 27 bridge draws in its failure mode
///    (rows at the fallback until a scroll re-tiles), so it must already be
///    the full row height.
/// 2. Every row the table lays out is exactly one floor tall — the fullest
///    row shape (two title lines, a domain, two excerpt lines) does not exceed
///    the floor, and the shortest shape is padded up to it. Pitch between
///    neighbouring rows equals the floor (zero intercell spacing).
///
/// A third check bounds the slack: the fullest row's natural height sits
/// within 0...6 pt below the floor, so `rowHeightMargin` can neither fall
/// short (clipping in the failure mode) nor drift high (wasted density).
///
/// Runs at every `AppTextSize` and at the narrowest (320 pt) and a wide
/// (600 pt) content column. No screen: the window is ordered offscreen.
@Suite("Entry row geometry", .serialized)
struct EntryRowGeometryTests {
  private static let widths: [CGFloat] = [320, 600]

  @Test("table fallback row height equals the floor", arguments: AppTextSize.allCases)
  @MainActor
  func fallbackRowHeightEqualsFloor(size: AppTextSize) async throws {
    let settings = AppFontSettings(textSize: size, userDefaults: Self.isolatedDefaults())
    let table = try await Self.hostList(settings: settings, width: 320)
    #expect(table.rowHeight == settings.entryRowHeight)
  }

  @Test("every row is exactly one floor tall and rows sit one floor apart", arguments: AppTextSize.allCases)
  @MainActor
  func rowRectsEqualFloor(size: AppTextSize) async throws {
    let settings = AppFontSettings(textSize: size, userDefaults: Self.isolatedDefaults())
    for width in Self.widths {
      let table = try await Self.hostList(settings: settings, width: width)
      #expect(table.numberOfRows == Self.sampleRows.count, "width \(width)")
      let rects = (0..<table.numberOfRows).map { table.rect(ofRow: $0) }
      for (index, rect) in rects.enumerated() {
        #expect(
          rect.height == settings.entryRowHeight,
          "size \(size) width \(width) row \(index) height \(rect.height) vs floor \(settings.entryRowHeight)")
      }
      for (upper, lower) in zip(rects, rects.dropFirst()) {
        #expect(
          lower.minY - upper.minY == settings.entryRowHeight,
          "size \(size) width \(width) pitch \(lower.minY - upper.minY) vs floor \(settings.entryRowHeight)")
      }
    }
  }

  @Test("the fullest row's natural height never exceeds the floor", arguments: AppTextSize.allCases)
  @MainActor
  func naturalHeightWithinFloor(size: AppTextSize) async throws {
    let settings = AppFontSettings(textSize: size, userDefaults: Self.isolatedDefaults())
    let ids = PreviewSupport.mintEntryIdentifiers(count: 1)
    for width in Self.widths {
      let contentWidth = width - 2 * EntryRowMetrics.horizontalInset
      let row = EntryRowView(row: Self.fullRow(id: ids[0]), faviconImage: nil)
        .environment(settings)
        .frame(width: contentWidth)
      let hosting = NSHostingView(rootView: row)
      let natural = hosting.fittingSize.height
      #expect(
        natural <= settings.entryRowHeight,
        "size \(size) width \(width): natural \(natural) exceeds floor \(settings.entryRowHeight)")
      #expect(
        settings.entryRowHeight - natural <= 6,
        "size \(size) width \(width): floor \(settings.entryRowHeight) leaves \(settings.entryRowHeight - natural) pt of slack above natural \(natural)"
      )
    }
  }

  // MARK: - Sample rows

  /// Row shapes the floor must equalise (mirrors the row-matrix previews).
  private static let sampleRows: [(title: String, domain: String?, excerpt: String)] = [
    (
      "A title long enough to wrap onto a second line in a narrow column and be truncated",
      "matrix.example.com", "Two lines of excerpt text so the summary slot is full at this width, and then some more."
    ),
    ("Short title", nil, ""),
    ("Read row", "a-very-long-subdomain.of-an-even-longer-domain.example.com", "One line."),
  ]

  @MainActor
  private static func fullRow(id: PersistentIdentifier) -> EntryRowDTO {
    makeRow(id: id, feedbinEntryID: 1, shape: sampleRows[0])
  }

  @MainActor
  private static func makeRow(
    id: PersistentIdentifier, feedbinEntryID: Int, shape: (title: String, domain: String?, excerpt: String)
  ) -> EntryRowDTO {
    EntryRowDTO(
      persistentID: id,
      feedbinEntryID: feedbinEntryID,
      title: shape.title,
      formattedPublishedTime: "09.30",
      displayDomain: shape.domain,
      excerpt: shape.excerpt,
      isRead: feedbinEntryID == 3,
      publishedAt: .now,
      feedFeedbinID: 1,
      feedInitial: "M"
    )
  }

  // MARK: - Hosting

  /// Hosts the `EntryListView` list shape offscreen and returns its table.
  @MainActor
  private static func hostList(settings: AppFontSettings, width: CGFloat) async throws -> NSTableView {
    let ids = PreviewSupport.mintEntryIdentifiers(count: sampleRows.count)
    let rows = zip(ids, sampleRows.indices).map { id, index in
      makeRow(id: id, feedbinEntryID: index + 1, shape: sampleRows[index])
    }
    let list = List(rows) { row in
      EntryRowView(row: row, faviconImage: nil)
        .listRowSeparator(.hidden)
        .listRowInsets(
          EdgeInsets(
            top: 0, leading: EntryRowMetrics.horizontalInset,
            bottom: 0, trailing: EntryRowMetrics.horizontalInset))
    }
    .listStyle(.inset(alternatesRowBackgrounds: false))
    .environment(\.defaultMinListRowHeight, settings.entryRowHeight)
    .environment(settings)
    let hosting = NSHostingView(rootView: list)
    hosting.frame = NSRect(x: -6000, y: -6000, width: width, height: 900)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    // One run-loop turn so the bridge creates and measures the table rows.
    try await Task.sleep(for: .milliseconds(200))
    hosting.layoutSubtreeIfNeeded()
    let tables = findTableViews(in: hosting)
    window.orderOut(nil)
    let table = try #require(tables.first, "no NSTableView under the hosting view")
    return table
  }

  @MainActor
  private static func findTableViews(in view: NSView) -> [NSTableView] {
    var result: [NSTableView] = []
    if let table = view as? NSTableView { result.append(table) }
    for subview in view.subviews {
      result.append(contentsOf: findTableViews(in: subview))
    }
    return result
  }

  private static func isolatedDefaults() -> UserDefaults {
    let name = "EntryRowGeometryTests"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
  }
}
