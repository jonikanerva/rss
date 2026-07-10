import Foundation
import SwiftData
import XCTest
import os
import os.signpost

@testable import Feeder

// MARK: - PerfSignpostTests

/// Level 2 of the perf suite: `XCTOSSignpostMetric` over the three click →
/// render signposts defined in `Feeder/Helpers/PerformanceSignposts.swift`.
/// Each test exercises the work the production click handler triggers
/// (fetch + aggregate + render) inside a single `measure(metrics:)` block so
/// XCTest captures the per-iteration duration of the named signpost.
///
/// SwiftUI commit cost is not measured here — Level 4 (`xctrace record`)
/// covers that. Level 2 is for catching regressions in the work the click
/// handlers perform: `DataReader.fetchEntrySections`,
/// `DataReader.fetchUnreadCountsSnapshot`, and `parseHTMLToBlocks`.
///
/// Not part of `make test-all`. Invoked by `make perf` via
/// `-only-testing:FeederTests/PerfSignpostTests`.
final class PerfSignpostTests: XCTestCase {
  private var container: ModelContainer!
  private var writer: DataWriter!
  private var reader: DataReader!

  // MARK: - Setup / teardown

  override func setUp() async throws {
    try await super.setUp()
    container = try DataWriterTestSupport.makeInMemoryContainer()
    writer = await DataWriter.makeDetached(modelContainer: container)
    // Article-list / unread reads moved to `DataReader`; the click signposts
    // exercise them on the reader over the same container.
    reader = await DataReader.makeDetached(modelContainer: container)
    // 200 entries is enough to spread across the categories without
    // pushing iteration time past ~5 s — Level 4 covers the 5k case.
    _ = try await writer.seedPerfTestData(entryCount: 200, categoryCount: 8)
  }

  override func tearDown() async throws {
    writer = nil
    reader = nil
    container = nil
    try await super.tearDown()
  }

  // MARK: - Tests

  func test_sidebar_click_signpost() async throws {
    let cutoff = Date.distantPast
    let folderLabel = "technology"
    let category = "perf_0"
    let reader = self.reader!
    let baseline = try await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoff)
    XCTAssertGreaterThan(baseline.totalUnread, 0, "Perf seeder must produce unread rows")

    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: Self.sidebarClickMetrics(), options: options) {
      let state = perfSignposter.beginInterval(PerformanceSignpostName.sidebarClick)
      let group = DispatchGroup()
      group.enter()
      Task {
        defer { group.leave() }
        _ = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoff)
        _ = try? await reader.fetchEntrySections(
          category: nil, folder: folderLabel, showRead: false,
          cutoffDate: cutoff, pinnedFeedbinEntryID: nil
        )
        _ = try? await reader.fetchEntrySections(
          category: category, folder: nil, showRead: false,
          cutoffDate: cutoff, pinnedFeedbinEntryID: nil
        )
      }
      group.wait()
      perfSignposter.endInterval(PerformanceSignpostName.sidebarClick, state)
    }
  }

  func test_article_click_signpost() async throws {
    let reader = self.reader!
    let category = "perf_0"
    let cutoff = Date.distantPast
    let result = try await reader.fetchEntrySections(
      category: category, folder: nil, showRead: false,
      cutoffDate: cutoff, pinnedFeedbinEntryID: nil
    )
    let firstEntryID = result.allEntryIDs.first
    XCTAssertNotNil(firstEntryID, "Perf seeder must produce at least one row in category \(category)")

    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: Self.articleClickMetrics(), options: options) {
      let state = perfSignposter.beginInterval(PerformanceSignpostName.articleClick)
      // The article-click work the production path performs is the
      // refetch of entry sections (already cached) plus snapshot refresh
      // when the row's read state flips. We mirror the same two calls so
      // the measured duration reflects the worst-case post-click work.
      let group = DispatchGroup()
      group.enter()
      Task {
        defer { group.leave() }
        _ = try? await reader.fetchEntrySections(
          category: category, folder: nil, showRead: false,
          cutoffDate: cutoff, pinnedFeedbinEntryID: nil
        )
        _ = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoff)
      }
      group.wait()
      perfSignposter.endInterval(PerformanceSignpostName.articleClick, state)
    }
  }

  func test_detail_render_signpost() async throws {
    // Use the renderer the production path uses. `parseHTMLToBlocks` runs
    // synchronously on the caller; the production detail view kicks it off
    // a detached task. Measuring it under the detail-render signpost
    // captures the renderer's cost without depending on a `WKWebView`.
    let html = String(
      repeating: "<p>Perf scenario story body with <em>emphasis</em> and a "
        + "<a href=\"https://example.com\">link</a>. </p>",
      count: 20
    )

    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: Self.detailRenderMetrics(), options: options) {
      let state = perfSignposter.beginInterval(PerformanceSignpostName.detailRender)
      _ = parseHTMLToBlocks(html)
      perfSignposter.endInterval(PerformanceSignpostName.detailRender, state)
    }
  }

  // MARK: - Metric helpers

  /// `XCTOSSignpostMetric` filters by interval-name string, captured from the
  /// signposter's emitted points. `name:` must match the `StaticString` we
  /// pass to `beginInterval` / `endInterval` exactly.
  private static func sidebarClickMetrics() -> [XCTMetric] {
    [
      XCTOSSignpostMetric(
        subsystem: "com.feeder.app",
        category: "PointsOfInterest",
        name: "sidebar-click"
      )
    ]
  }

  private static func articleClickMetrics() -> [XCTMetric] {
    [
      XCTOSSignpostMetric(
        subsystem: "com.feeder.app",
        category: "PointsOfInterest",
        name: "article-click"
      )
    ]
  }

  private static func detailRenderMetrics() -> [XCTMetric] {
    [
      XCTOSSignpostMetric(
        subsystem: "com.feeder.app",
        category: "PointsOfInterest",
        name: "detail-render"
      )
    ]
  }
}
