import Foundation
import SwiftData
import XCTest

@testable import Feeder

// MARK: - MicroBenchmarkTests

/// Level 1 of the perf suite: function-level micro-benchmarks for the hot-path
/// operations identified during PR 4 planning. Each test wraps a focused call
/// in XCTest's `measure { }` so the test framework captures per-iteration
/// duration and tracks drift over time.
///
/// Per `VISION.md → Core Principles` (evidence over opinion) and the
/// boss's explicit PR-4 decision: performance is app-rule #1, so the perf
/// gate is foundational, not deferred. These benchmarks complement the Level
/// 2 signposts (`PerfSignpostTests`) and Level 4 traces (`make perf-trace`)
/// by isolating individual hot functions:
///
/// - `DataReader.fetchUnreadCountsSnapshot(cutoffDate:)`
/// - `DataReader.fetchEntrySections(category:folder:showRead:cutoffDate:pinnedFeedbinEntryID:)`
/// - `parseHTMLToBlocks(_:)`
/// - `groupEntriesByDay(_:)`
///
/// Not part of `make test-all`. Invoked by `make perf` via
/// `-only-testing:FeederTests/MicroBenchmarkTests` so they ride the same
/// perf-only gate the signpost suite uses. Baselines live in
/// `Tests/PerfBaselines/baseline-current.json` under `level1_microbench`.
///
/// Iteration count is intentionally low (5) so the suite still finishes
/// well inside the perf-trace iteration budget. The signal we want is "did
/// this function regress meaningfully" — not statistical certainty.
final class MicroBenchmarkTests: XCTestCase {
  private var container: ModelContainer!
  private var writer: DataWriter!
  private var reader: DataReader!

  // MARK: - Setup / teardown

  override func setUp() async throws {
    try await super.setUp()
    container = try DataWriterTestSupport.makeInMemoryContainer()
    writer = await DataWriter.makeDetached(modelContainer: container)
    // Article-list / unread reads moved to `DataReader`; benchmark them on the
    // reader over the same container.
    reader = await DataReader.makeDetached(modelContainer: container)
    // 1000 entries spread across 8 categories is realistic enough to make
    // SQLite predicate cost dominate, without pushing iteration time past
    // ~5s on M-series hosts.
    _ = try await writer.seedPerfTestData(entryCount: 1000, categoryCount: 8)
  }

  override func tearDown() async throws {
    writer = nil
    reader = nil
    container = nil
    try await super.tearDown()
  }

  // MARK: - DataReader.fetchUnreadCountsSnapshot

  /// Pinpoints regression risk in the sidebar's cold-render path. The
  /// snapshot fetch is what drives every badge count, so any drift here
  /// shows up in the cold-launch frame budget immediately.
  func test_fetchUnreadCountsSnapshot_micro() async throws {
    let reader = self.reader!
    let cutoff = Date.distantPast

    // Warm the SwiftData container so the first measured iteration does
    // not pay for cold descriptor compilation. `measure` ignores its
    // setup cost, but a cold first call still skews the median.
    _ = try await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoff)

    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(options: options) {
      let group = DispatchGroup()
      group.enter()
      Task {
        defer { group.leave() }
        _ = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoff)
      }
      group.wait()
    }
  }

  // MARK: - DataReader.fetchEntrySections

  /// Pinpoints regression risk in the article-list cold-render path. The
  /// `category` axis is the more common selection — the `folder` axis is
  /// covered by `PerfSignpostTests.test_sidebar_click_signpost`.
  func test_fetchEntrySections_category_micro() async throws {
    let reader = self.reader!
    let cutoff = Date.distantPast
    let category = "perf_0"

    // Warm — same rationale as above.
    _ = try await reader.fetchEntrySections(
      category: category, folder: nil, showRead: false,
      cutoffDate: cutoff, pinnedFeedbinEntryID: nil
    )

    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(options: options) {
      let group = DispatchGroup()
      group.enter()
      Task {
        defer { group.leave() }
        _ = try? await reader.fetchEntrySections(
          category: category, folder: nil, showRead: false,
          cutoffDate: cutoff, pinnedFeedbinEntryID: nil
        )
      }
      group.wait()
    }
  }

  // MARK: - parseHTMLToBlocks

  /// Pinpoints regression risk in the article detail view's render path.
  /// The fixture is a representative article body — multiple paragraphs,
  /// inline formatting, a list, a blockquote, an image — sized roughly to
  /// the median real-world feed entry.
  func test_parseHTMLToBlocks_micro() {
    let html = Self.representativeArticleHTML

    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(options: options) {
      _ = parseHTMLToBlocks(html)
    }
  }

  // MARK: - groupEntriesByDay

  /// Pinpoints regression risk in the article-list grouping path. The
  /// function is called inside `fetchEntrySections` on every reload, so
  /// any regression compounds with the sidebar-click signpost cost.
  ///
  /// `groupEntriesByDay` reads `@Model Entry` properties, which require an
  /// active `ModelContext`. We seed entries via `DataWriter` (the
  /// `seedPerfTestData` path), then drive the measurement from inside the
  /// writer actor so the entries are alive in the actor's context for the
  /// duration of the benchmark.
  func test_groupEntriesByDay_micro() async throws {
    let writer = self.writer!
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(options: options) {
      let group = DispatchGroup()
      group.enter()
      Task {
        defer { group.leave() }
        _ = try? await writer.measureGroupEntriesByDay()
      }
      group.wait()
    }
  }

  // MARK: - Fixtures

  /// A representative ~2 KB article HTML payload, exercising the main DOM
  /// shapes `parseHTMLToBlocks` walks: paragraphs with inline emphasis and
  /// links, a heading hierarchy, an unordered list, a blockquote, an
  /// image, and an inline code span. Inlined rather than loaded from disk
  /// so the benchmark stays hermetic and `measure { }` does not pay for
  /// filesystem I/O on every iteration.
  private static let representativeArticleHTML: String = """
    <article>
      <h1>The Quiet Revolution in Local Compute</h1>
      <p>
        Apple's announcement at <a href="https://www.apple.com/">WWDC</a> last week
        revealed that <em>on-device intelligence</em> is no longer a research
        novelty. Developers now have <strong>first-class APIs</strong> for
        running large language models on the Mac.
      </p>
      <h2>What changed</h2>
      <p>
        Three things shifted at once: the runtime got smaller, the memory
        footprint dropped, and the <code>FoundationModels</code> framework
        landed in the public SDK. Together these enable apps like Feeder to
        classify articles entirely offline.
      </p>
      <ul>
        <li>Runtime: ~120 MB resident under steady-state inference.</li>
        <li>Latency: median 180 ms per short prompt on an M3.</li>
        <li>Privacy: zero network egress when the on-device path is taken.</li>
      </ul>
      <blockquote>
        <p>
          "We're not asking developers to choose between privacy and
          capability. The point is to have both."
        </p>
      </blockquote>
      <h2>Implications for RSS</h2>
      <p>
        Categorisation has been the lever Feeder pulls. The new runtime lets
        every ingested article get a category assignment within the same
        sync pass, with no API key or network round-trip. The next step is
        <em>per-user category taxonomies</em> — your own buckets, classified
        on your own machine.
      </p>
      <img src="https://example.com/foundation-models.png" alt="Diagram of on-device inference pipeline" />
      <p>
        For reading apps specifically, this matters because the
        classification path was previously the only place a privacy-leaking
        third-party call could land. With Foundation Models in the stack,
        Feeder ships an end-to-end offline reading experience.
      </p>
    </article>
    """
}

// MARK: - DataWriter actor entry point for grouping benchmark

extension DataWriter {
  /// Fetches the seeded entries inside the writer's actor context and
  /// hands them to `groupEntriesByDay` — `Entry` properties are not
  /// readable from MainActor without the model context, so the benchmark
  /// must drive grouping from inside the actor.
  func measureGroupEntriesByDay() throws -> [EntryListSection] {
    let entries = try modelContext.fetch(
      FetchDescriptor<Entry>(sortBy: [SortDescriptor(\Entry.publishedAt, order: .reverse)])
    )
    return groupEntriesByDay(entries)
  }
}
