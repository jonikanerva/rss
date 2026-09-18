import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import Feeder

/// Headless geometry check for the row-height floor and the title / summary
/// split. Hosts the same `List` shape `EntryListView` renders — inset
/// style, hidden separators, explicit row insets, `defaultMinListRowHeight`
/// floor — in an offscreen `NSHostingView`, then reads the backing
/// `NSTableView` through public API. Invariants:
///
/// 1. The table's fallback row height (`NSTableView.rowHeight`) equals the
///    floor. This is the value the macOS 27 bridge draws in its failure mode
///    (rows at the fallback until a scroll re-tiles), so it must already be
///    the full row height.
/// 2. Every row the table lays out is exactly one floor tall and rows sit one
///    floor apart (zero intercell spacing), for every row shape.
/// 3. Every row shape's natural height is the floor minus
///    `rowHeightMargin`, exactly: the text column has a fixed height, so the
///    content shape cannot move the row height.
/// 4. The split fits the column budget (T1): the heights SwiftUI lays the
///    title row, the domain line and the summary out at leave room for three
///    summary lines under a one-line title and two under a two-line title.
/// 5. The rendered line counts (T2): an `ImageRenderer` bitmap of the row is
///    scanned for ink bands. A one-line title shows three summary lines, a
///    two-line title two; the bands are equally tall; the bottom padding has
///    no ink (the `.frame` does not clip, so overflow would land there).
///
/// Runs at every `AppTextSize` and at three content-column widths: 200 pt
/// (the platform's default column width; the column has no width bound, so
/// 200 is a shipped state), 320 pt and 600 pt. No screen: the window is
/// ordered offscreen and the bitmap render needs no window.
@Suite("Entry row geometry", .serialized)
struct EntryRowGeometryTests {
  private static let widths: [CGFloat] = [200, 320, 600]

  // MARK: - Floor

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

  @Test("every row shape's natural height is the floor minus the margin", arguments: AppTextSize.allCases)
  @MainActor
  func naturalHeightIsFloorMinusMargin(size: AppTextSize) {
    let settings = AppFontSettings(textSize: size, userDefaults: Self.isolatedDefaults())
    let ids = PreviewSupport.mintEntryIdentifiers(count: Self.sampleRows.count)
    for width in Self.widths {
      let contentWidth = width - 2 * EntryRowMetrics.horizontalInset
      for (index, shape) in Self.sampleRows.enumerated() {
        let row = EntryRowView(row: Self.makeRow(id: ids[index], feedbinEntryID: index + 1, shape: shape), faviconImage: nil)
          .environment(settings)
          .frame(width: contentWidth)
        let natural = NSHostingView(rootView: row).fittingSize.height
        #expect(
          settings.entryRowHeight - natural == EntryRowMetrics.rowHeightMargin,
          "size \(size) width \(width) shape \(index): floor \(settings.entryRowHeight) vs natural \(natural)")
      }
    }
  }

  // MARK: - T1: the split fits the column budget

  @Test("title, domain and summary line heights fit the fixed column", arguments: AppTextSize.allCases)
  @MainActor
  func lineHeightsFitColumn(size: AppTextSize) {
    let settings = AppFontSettings(textSize: size, userDefaults: Self.isolatedDefaults())
    let column = settings.entryRowTextColumnHeight
    let summaryLine = EntryRowMetrics.lineHeights(scale: size.scaleFactor).summary
    let gaps = 2 * EntryRowMetrics.textSpacing
    for width in Self.widths {
      let columnWidth =
        width - 2 * EntryRowMetrics.horizontalInset - EntryRowMetrics.faviconSize - EntryRowMetrics.faviconSpacing
      let oneLine = Self.titleRowHeight(Self.oneLineTitle, settings: settings, width: columnWidth)
      let twoLines = Self.titleRowHeight(Self.longTitle, settings: settings, width: columnWidth)
      let oneLineRead = Self.titleRowHeight(Self.oneLineTitle, settings: settings, width: columnWidth, weight: .regular)
      let emojiOneLine = Self.titleRowHeight(Self.emojiOneLineTitle, settings: settings, width: columnWidth)
      let emojiTwoLines = Self.titleRowHeight(Self.emojiLongTitle, settings: settings, width: columnWidth)
      let domain = Self.domainHeight(Self.domain, settings: settings, width: columnWidth)
      let placeholderDomain = Self.domainHeight(
        EntryRowMetrics.reservedDomainPlaceholder, settings: settings, width: columnWidth)
      let emptyStringDomain = Self.domainHeight("", settings: settings, width: columnWidth)
      let oneSummaryLine = Self.summaryHeight("xxxx", limit: EntryRowMetrics.excerptLineLimit, settings: settings, width: columnWidth)
      let twoSummaryLines = Self.summaryHeight(Self.longExcerpt, limit: 2, settings: settings, width: columnWidth)
      let threeSummaryLines = Self.summaryHeight(Self.longExcerpt, limit: 3, settings: settings, width: columnWidth)
      let emptySummary = Self.summaryHeight("", limit: EntryRowMetrics.excerptLineLimit, settings: settings, width: columnWidth)
      let context: Comment = "size \(size) width \(width)"

      // The two shipped splits fit the column: the heights SwiftUI lays the
      // slots out at, summed, never exceed the fixed column. (SwiftUI's line
      // pitch differs from the `NSFont` arithmetic by up to 1 pt per slot in
      // either direction, so the measured sum is the check, not the offer
      // against an arithmetic line height.)
      #expect(oneLine + gaps + domain + threeSummaryLines <= column, context)
      #expect(twoLines + gaps + domain + twoSummaryLines <= column, context)
      #expect(oneLine + gaps + domain + emptySummary <= column, context)
      #expect(twoLines + gaps + domain + emptySummary <= column, context)
      // The extra summary line under a one-line title is a whole line.
      #expect(threeSummaryLines - twoSummaryLines >= oneSummaryLine - 1, context)
      #expect(oneLine + oneSummaryLine <= twoLines, context)
      // Emoji may grow the title line; the summary keeps at least two lines
      // under a one-line title and at least one under a two-line title.
      #expect(emojiOneLine + gaps + domain + twoSummaryLines <= column, context)
      #expect(emojiTwoLines + gaps + domain + oneSummaryLine <= column, context)
      // The reserved domain line and the weight swap have no height effect.
      #expect(placeholderDomain == domain, context)
      #expect(oneLineRead == oneLine, context)
      // An EMPTY `Text` with reserved space is 14 pt at every size, not the
      // font's line height: the reason the row never renders "" directly.
      #expect(emptyStringDomain == 14, context)
      // The arithmetic the floor is built from stays at or above the layout.
      #expect(summaryLine >= oneSummaryLine - 1, context)
    }
  }

  // MARK: - T2: rendered line counts

  /// One rendered row shape and the ink bands it must show. Summary counts
  /// are ranges: emoji titles may take a taller line and cost one summary
  /// line, but never all of them.
  private struct RenderCase {
    let name: String
    let shape: RowShape
    let titleLines: Int
    let summaryLines: ClosedRange<Int>
  }

  private static let renderCases: [RenderCase] = [
    RenderCase(
      name: "one-line title, long excerpt",
      shape: RowShape(title: oneLineTitle, domain: domain, excerpt: longExcerpt), titleLines: 1, summaryLines: 3...3),
    RenderCase(
      name: "two-line title, long excerpt",
      shape: RowShape(title: longTitle, domain: domain, excerpt: longExcerpt), titleLines: 2, summaryLines: 2...2),
    RenderCase(
      name: "one-line title, no domain, long excerpt",
      shape: RowShape(title: oneLineTitle, domain: nil, excerpt: longExcerpt), titleLines: 1, summaryLines: 3...3),
    RenderCase(
      name: "two-line title, no domain, long excerpt",
      shape: RowShape(title: longTitle, domain: nil, excerpt: longExcerpt), titleLines: 2, summaryLines: 2...2),
    RenderCase(
      name: "one-line title, empty-string domain, long excerpt",
      shape: RowShape(title: oneLineTitle, domain: "", excerpt: longExcerpt), titleLines: 1, summaryLines: 3...3),
    RenderCase(
      name: "two-line title, empty-string domain, long excerpt",
      shape: RowShape(title: longTitle, domain: "", excerpt: longExcerpt), titleLines: 2, summaryLines: 2...2),
    RenderCase(
      name: "one-line title, empty excerpt",
      shape: RowShape(title: oneLineTitle, domain: domain, excerpt: ""), titleLines: 1, summaryLines: 0...0),
    RenderCase(
      name: "two-line title, empty excerpt",
      shape: RowShape(title: longTitle, domain: domain, excerpt: ""), titleLines: 2, summaryLines: 0...0),
    RenderCase(
      name: "read one-line title, long excerpt",
      shape: RowShape(title: oneLineTitle, domain: domain, excerpt: longExcerpt, isRead: true),
      titleLines: 1, summaryLines: 3...3),
    RenderCase(
      name: "emoji one-line title, long excerpt",
      shape: RowShape(title: emojiOneLineTitle, domain: domain, excerpt: longExcerpt), titleLines: 1, summaryLines: 2...3),
    RenderCase(
      name: "emoji two-line title, long excerpt",
      shape: RowShape(title: emojiLongTitle, domain: domain, excerpt: longExcerpt), titleLines: 2, summaryLines: 1...2),
  ]

  @Test(
    "a one-line title leaves three summary lines, a two-line title two, and nothing overflows the column",
    arguments: AppTextSize.allCases)
  @MainActor
  func renderedLineCounts(size: AppTextSize) throws {
    let settings = AppFontSettings(textSize: size, userDefaults: Self.isolatedDefaults())
    let heights = EntryRowMetrics.lineHeights(scale: size.scaleFactor)
    let ids = PreviewSupport.mintEntryIdentifiers(count: Self.renderCases.count)
    let rowTop = Int(EntryRowMetrics.verticalPadding)
    let columnBottom = rowTop + Int(settings.entryRowTextColumnHeight)
    for width in Self.widths {
      for (index, renderCase) in Self.renderCases.enumerated() {
        let row = Self.makeRow(id: ids[index], feedbinEntryID: index + 1, shape: renderCase.shape)
        let scan = try Self.renderInk(row: row, settings: settings, width: width)
        let context = "size \(size) width \(width) \(renderCase.name)"
        let titleHeight = renderCase.titleLines * Int(heights.title)
        let domainTop = rowTop + titleHeight + Int(EntryRowMetrics.textSpacing)
        let summaryTop = domainTop + Int(heights.meta) + Int(EntryRowMetrics.textSpacing) - 1

        // The bitmap is exactly the row's natural height: column + padding.
        #expect(scan.height == columnBottom + rowTop, "\(context): image height \(scan.height)")
        // (iii) The title shows exactly its line count.
        let titleBands = scan.bands(in: rowTop..<(rowTop + titleHeight + 1))
        #expect(titleBands.count == renderCase.titleLines, "\(context): title bands \(titleBands)")
        // The domain line is present when set and empty when nil.
        let domainBands = scan.bands(in: domainTop..<(domainTop + Int(heights.meta)))
        let hasDomain = renderCase.shape.domain.map { !$0.isEmpty } ?? false
        #expect(domainBands.count == (hasDomain ? 1 : 0), "\(context): domain bands \(domainBands)")
        // The summary shows the expected whole lines under the title.
        let summaryBands = scan.bands(in: summaryTop..<columnBottom)
        #expect(renderCase.summaryLines.contains(summaryBands.count), "\(context): summary bands \(summaryBands)")
        // (i) Every summary line is drawn whole: equal band heights.
        let bandHeights = summaryBands.map(\.count)
        if let tallest = bandHeights.max(), let shortest = bandHeights.min() {
          #expect(tallest - shortest <= 1, "\(context): summary band heights \(bandHeights)")
        }
        // (ii) Nothing overflows into the bottom padding.
        let bottomBands = scan.bands(in: columnBottom..<scan.height)
        #expect(bottomBands.isEmpty, "\(context): ink in the bottom padding \(bottomBands)")
      }
    }
  }

  // MARK: - Sample rows

  /// One row's content. `domain == nil` and `domain == ""` both render the
  /// reserved empty domain line; `isRead` swaps the title weight to regular.
  nonisolated private struct RowShape: Sendable {
    let title: String
    let domain: String?
    let excerpt: String
    var isRead = false
  }

  /// Short enough to stay on one line next to the time label at 200 pt and
  /// the huge text size.
  private static let oneLineTitle = "xxxx"
  /// Wraps past two lines at every width and size; descender-free glyphs so
  /// each rendered line is one ink band.
  private static let longTitle = Array(repeating: "xxxx", count: 120).joined(separator: " ")
  private static let emojiOneLineTitle = "🚀 xx"
  private static let emojiLongTitle = "🚀 " + longTitle
  private static let domain = "xxxx.xxx"
  private static let longDomain = "a-very-long-subdomain.of-an-even-longer-domain.example.com"
  private static let longExcerpt = Array(repeating: "xxxx", count: 300).joined(separator: " ")

  /// Row shapes the floor must equalise (mirrors the row-matrix previews).
  private static let sampleRows: [RowShape] = [
    RowShape(title: longTitle, domain: domain, excerpt: longExcerpt),
    RowShape(title: oneLineTitle, domain: domain, excerpt: longExcerpt),
    RowShape(title: oneLineTitle, domain: nil, excerpt: ""),
    RowShape(title: longTitle, domain: nil, excerpt: longExcerpt),
    RowShape(title: longTitle, domain: "", excerpt: longExcerpt),
    RowShape(title: longTitle, domain: domain, excerpt: ""),
    RowShape(title: oneLineTitle, domain: longDomain, excerpt: "One line.", isRead: true),
    RowShape(title: emojiOneLineTitle, domain: domain, excerpt: longExcerpt),
    RowShape(title: emojiLongTitle, domain: domain, excerpt: longExcerpt),
  ]

  @MainActor
  private static func makeRow(id: PersistentIdentifier, feedbinEntryID: Int, shape: RowShape) -> EntryRowDTO {
    EntryRowDTO(
      persistentID: id,
      feedbinEntryID: feedbinEntryID,
      title: shape.title,
      formattedPublishedTime: "09.30",
      displayDomain: shape.domain,
      excerpt: shape.excerpt,
      isRead: shape.isRead,
      publishedAt: .now,
      feedFeedbinID: 1,
      feedInitial: "M"
    )
  }

  // MARK: - Probes (T1)

  /// Natural height of `view` laid out at `width`, through the same
  /// `NSHostingView` measurement the floor tests use.
  @MainActor
  private static func probeHeight(of view: some View, width: CGFloat) -> CGFloat {
    NSHostingView(rootView: view.frame(width: width, alignment: .leading)).fittingSize.height
  }

  /// The title row as `EntryRowView` lays it out: title text, spacer, time.
  @MainActor
  private static func titleRowHeight(
    _ title: String, settings: AppFontSettings, width: CGFloat, weight: Font.Weight = .semibold
  ) -> CGFloat {
    let row = HStack(alignment: .top, spacing: EntryRowMetrics.titleTimeSpacing) {
      Text(title)
        .font(settings.rowTitle)
        .fontWeight(weight)
        .lineLimit(EntryRowMetrics.titleLineLimit)
      Spacer()
      Text("09.30")
        .font(settings.rowFeedName)
    }
    return probeHeight(of: row, width: width)
  }

  @MainActor
  private static func domainHeight(_ domain: String, settings: AppFontSettings, width: CGFloat) -> CGFloat {
    let line = Text(domain)
      .font(settings.rowFeedName)
      .lineLimit(EntryRowMetrics.domainLineLimit, reservesSpace: true)
      .truncationMode(.middle)
    return probeHeight(of: line, width: width)
  }

  @MainActor
  private static func summaryHeight(_ excerpt: String, limit: Int, settings: AppFontSettings, width: CGFloat) -> CGFloat {
    let summary = Text(excerpt)
      .font(settings.rowSummary)
      .lineLimit(limit)
    return probeHeight(of: summary, width: width)
  }

  // MARK: - Bitmap scan (T2)

  /// Per-row ink flags of a rendered bitmap, top row first, plus the band
  /// grouping the assertions read.
  nonisolated private struct InkScan: Sendable {
    let inkRows: [Bool]
    var height: Int { inkRows.count }

    /// Runs of consecutive ink rows inside `range`, as inclusive row ranges.
    func bands(in range: Range<Int>) -> [ClosedRange<Int>] {
      var bands: [ClosedRange<Int>] = []
      var start: Int?
      for y in range {
        let ink = inkRows.indices.contains(y) && inkRows[y]
        if ink, start == nil { start = y }
        if !ink, let bandStart = start {
          bands.append(bandStart...(y - 1))
          start = nil
        }
      }
      if let bandStart = start { bands.append(bandStart...(range.upperBound - 1)) }
      return bands
    }
  }

  /// Renders the shipped `EntryRowView` at the content width of a `width`-pt
  /// column on a white background in light mode, at 1 px per point, and
  /// scans the text column (right of the favicon, left of the time label)
  /// for rows with any dark pixel.
  @MainActor
  private static func renderInk(row: EntryRowDTO, settings: AppFontSettings, width: CGFloat) throws -> InkScan {
    let contentWidth = width - 2 * EntryRowMetrics.horizontalInset
    let view = EntryRowView(row: row, faviconImage: nil)
      .environment(settings)
      .frame(width: contentWidth)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let image = try #require(renderer.cgImage, "ImageRenderer produced no image")
    let textStart = Int(EntryRowMetrics.faviconSize + EntryRowMetrics.faviconSpacing)
    let textEnd = image.width - 80
    return try scanInk(image, xRange: textStart..<textEnd)
  }

  /// Draws `image` into an RGBA bitmap and flags every row that has a pixel
  /// darker than the luminance threshold inside `xRange`. Bitmap memory
  /// starts at the TOP row, so index 0 is the top of the image.
  private static func scanInk(_ image: CGImage, xRange: Range<Int>) throws -> InkScan {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    let inkRows: [Bool] = try pixels.withUnsafeMutableBytes { buffer in
      let context = try #require(
        CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * bytesPerPixel, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        "no bitmap context")
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let bytes = buffer.bindMemory(to: UInt8.self)
      return (0..<height).map { y in
        xRange.contains { x in
          let offset = (y * width + x) * bytesPerPixel
          let luminance =
            (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset + 2]))
            / 255
          return luminance < 0.85
        }
      }
    }
    return InkScan(inkRows: inkRows)
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
    hosting.frame = NSRect(x: -6000, y: -6000, width: width, height: 1200)
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
