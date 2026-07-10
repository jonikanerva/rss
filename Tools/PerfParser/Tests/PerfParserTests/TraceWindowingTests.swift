import Foundation
import Testing

@testable import PerfParser

// MARK: - Nav-window hang windowing + sidebar-nav bucket

/// Covers the Level 4 additions for the keyboard-nav stutter harness:
/// resolving the `perf-nav-window` signpost interval, windowing hang counts to
/// that interval (in-window vs out-of-window), and the `sidebar_nav_getter_pct`
/// symbol bucket. The parser shells out to `xctrace export` in production; the
/// pure parse + count functions are exercised here on hand-built fixture XML so
/// the windowing rule is validated deterministically without a real trace.
@Suite("Trace nav-window windowing")
struct TraceWindowingTests {
  // MARK: - Signpost window resolution

  @Test("Resolves an interval-row signpost into [start, start+duration]")
  func resolvesIntervalRow() throws {
    let window = TraceMetricsAggregator.parseSignpostWindow(
      xml: Data(Self.intervalRowSignpostXML.utf8), name: "perf-nav-window")
    let unwrapped = try #require(window)
    #expect(unwrapped.start == 1000)
    #expect(unwrapped.end == 6000)
  }

  @Test("Resolves a Begin/End signpost pair")
  func resolvesBeginEndPair() throws {
    let window = TraceMetricsAggregator.parseSignpostWindow(
      xml: Data(Self.beginEndSignpostXML.utf8), name: "perf-nav-window")
    let unwrapped = try #require(window)
    #expect(unwrapped.start == 2000)
    #expect(unwrapped.end == 7000)
  }

  @Test("Returns nil when the named interval is absent")
  func returnsNilWhenMissing() {
    let window = TraceMetricsAggregator.parseSignpostWindow(
      xml: Data(Self.intervalRowSignpostXML.utf8), name: "no-such-interval")
    #expect(window == nil)
  }

  // MARK: - Real xctrace export format (id/ref interning, issue #132)

  @Test("Resolves perf-nav-window from the real signpost format with id/ref interning")
  func resolvesRealSignpostFormat() throws {
    // The real export names columns <event-time>/<event-type>/<signpost-name>
    // and interns repeats as <element ref="N"/>. The perf-nav-window End row
    // refs BOTH its event-type and its name, so this only resolves if refs are
    // followed back to their defining rows.
    let window = TraceMetricsAggregator.parseSignpostWindow(
      xml: Data(Self.realSignpostXML.utf8), name: "perf-nav-window")
    let unwrapped = try #require(window)
    #expect(unwrapped.start == 1000)
    #expect(unwrapped.end == 18000)
  }

  @Test("Render floor holds on the real signpost format (ref-resolved sidebar-click)")
  func floorHoldsOnRealFormat() {
    let rows = TraceMetricsAggregator.parseSignpostRows(xml: Data(Self.realSignpostXML.utf8))
    #expect(
      TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: "sidebar-click", window: (start: 1000, end: 18000)))
  }

  @Test("Time-profile shares resolve interned frames AND weights (real format)")
  func timeProfileResolvesInterning() throws {
    // Four samples, each weight 1.00 ms via <weight ref>. Sample 3 names
    // ContentView.body.getter only through <frame ref>. Correct output needs
    // BOTH resolutions: every sample weighted 1_000_000 (not 1), and sample 3
    // counted into body. Expect body 2/4 = 50 %, sidebar-nav 1/4 = 25 %.
    let shares = try TraceMetricsAggregator.parseTimeProfile(
      xml: Data(Self.realTimeProfileXML.utf8))
    #expect(shares.bodyPct == 50)
    #expect(shares.sidebarNavPct == 25)
    #expect(shares.unreadPct == 0)
  }

  // MARK: - Render-path non-degeneracy floor (issue #132)

  @Test("Floor witness (sidebar-click) resolves inside the window")
  func floorWitnessPresentInWindow() {
    let rows = TraceMetricsAggregator.parseSignpostRows(
      xml: Data(Self.fullRenderSignpostXML.utf8))
    #expect(
      TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: TraceMetricsAggregator.requiredRenderSignpostName,
        window: (start: 1000, end: 6000)))
  }

  @Test("Floor scans past a pre-window occurrence to a later in-window one")
  func floorScansPastPreWindowOccurrence() {
    // `sidebar-click` fires once from the runner's pre-window `navigate(.next)`
    // priming step (start 100, outside [1000, 6000]) and again inside the
    // window (start 1200). A first-match resolver would reject this healthy
    // run; the floor must find the later in-window occurrence.
    let rows = TraceMetricsAggregator.parseSignpostRows(
      xml: Data(Self.fullRenderSignpostXML.utf8))
    #expect(
      TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: "sidebar-click", window: (start: 1000, end: 6000)))
  }

  @Test("Floor fails when a render signpost occurs only OUTSIDE the window")
  func floorFailsWhenOnlyOutsideWindow() {
    // Only the pre-window `sidebar-click` (start 100) exists — nothing rendered
    // inside [1000, 6000], so the floor must reject it.
    let rows = TraceMetricsAggregator.parseSignpostRows(
      xml: Data(Self.preWindowOnlySignpostXML.utf8))
    #expect(
      !TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: "sidebar-click", window: (start: 1000, end: 6000)))
  }

  @Test("Floor fails when a render signpost is entirely absent")
  func floorFailsWhenSignpostAbsent() {
    // `fullRenderSignpostXML` carries sidebar/article/detail; a name that never
    // appears (a stand-in for a missing render path) must fail the floor.
    let rows = TraceMetricsAggregator.parseSignpostRows(
      xml: Data(Self.preWindowOnlySignpostXML.utf8))
    #expect(
      !TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: "detail-render", window: (start: 1000, end: 6000)))
  }

  @Test("Floor accepts a Begin/End pair that opens inside the window")
  func floorAcceptsBeginEndPair() {
    let rows = TraceMetricsAggregator.parseSignpostRows(
      xml: Data(Self.beginEndRenderSignpostXML.utf8))
    #expect(
      TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: "detail-render", window: (start: 1000, end: 6000)))
  }

  @Test("Floor rejects a zero-duration interval row")
  func floorRejectsZeroDuration() {
    // A row with duration 0 is not a positive-duration render — it must not
    // satisfy the floor.
    let rows = TraceMetricsAggregator.parseSignpostRows(
      xml: Data(Self.zeroDurationRenderSignpostXML.utf8))
    #expect(
      !TraceMetricsAggregator.hasRenderSignpostInWindow(
        rows: rows, name: "article-click", window: (start: 1000, end: 6000)))
  }

  // MARK: - Hang parsing + windowing

  @Test("Parses hang start-times and durations")
  func parsesHangEvents() throws {
    let events = try TraceMetricsAggregator.parseHangEvents(xml: Data(Self.hangsXML.utf8))
    #expect(events.count == 4)
    // Durations are reported in nanoseconds and converted to ms.
    #expect(events.contains { $0.durationMs == 300 && $0.startTime == 1500 })
    #expect(events.contains { $0.durationMs == 600 && $0.startTime == 8000 })
  }

  @Test("Windows hang counts to the nav interval; whole-trace keeps all")
  func windowsHangCounts() throws {
    let events = try TraceMetricsAggregator.parseHangEvents(xml: Data(Self.hangsXML.utf8))
    let counts = TraceMetricsAggregator.countHangs(events, window: (start: 1000, end: 6000))
    // Whole trace: all four rows are >= 250 ms; rows 2 (600) and 3 (550) are
    // >= 500 ms.
    #expect(counts.micro == 4)
    #expect(counts.full == 2)
    // In-window [1000, 6000]: row1 (start 1500, 300 ms) and row3 (start 2000,
    // 550 ms). Row2 (8000) and row4 (500) fall outside.
    #expect(counts.microInWindow == 2)
    #expect(counts.fullInWindow == 1)
  }

  @Test("A nil window yields NOT-CAPTURED windowed counts, full whole-trace counts")
  func nilWindowYieldsNotCapturedWindowed() throws {
    let events = try TraceMetricsAggregator.parseHangEvents(xml: Data(Self.hangsXML.utf8))
    let counts = TraceMetricsAggregator.countHangs(events, window: nil)
    // Whole-trace counts always report.
    #expect(counts.micro == 4)
    #expect(counts.full == 2)
    // Case (a) — no signpost table: windowed counts are nil ("not captured"),
    // NOT 0. A zero would falsely read as "no stutter in the window".
    #expect(counts.microInWindow == nil)
    #expect(counts.fullInWindow == nil)
  }

  // MARK: - Sidebar-nav symbol bucket

  @Test("Sums the sidebar-nav recompute symbols into sidebar_nav_getter_pct")
  func sumsSidebarNavBucket() throws {
    let shares = try TraceMetricsAggregator.parseTimeProfile(xml: Data(Self.timeProfileXML.utf8))
    // Total weight 100: body 10, unread 8, sidebar-nav (6 + 6) 12.
    #expect(shares.bodyPct == 10)
    #expect(shares.unreadPct == 8)
    #expect(shares.sidebarNavPct == 12)
  }

  // MARK: - Report-only (null-max) comparator contract

  @Test("Null-max hang + nav metrics SKIP while body/unread still gate")
  func nullMaxMetricsAreReportOnly() throws {
    let baseline = try JSONDecoder().decode(
      BaselineDocument.self, from: Data(Self.navHarnessBaselineJSON.utf8))
    // Captured metrics that blow past the (null) hang + nav ceilings but stay
    // under the active body/unread ceilings → still a PASS, because every
    // null-max metric SKIPs.
    let underActive = TraceMetrics(
      contentviewBodyGetterPct: 3, contentviewUnreadEntriesGetterPct: 0,
      sidebarNavGetterPct: 42,
      microhangsGe250MsCount: 99, fullHangsGe500MsCount: 40,
      microhangsInNavWindow: 30, fullHangsInNavWindow: 12)
    #expect(compareTraceMetrics(underActive, baseline: baseline) == true)

    // Body share over its 9 % ceiling → FAIL: the active gate still bites.
    let overBody = TraceMetrics(
      contentviewBodyGetterPct: 33.8, contentviewUnreadEntriesGetterPct: 0,
      sidebarNavGetterPct: 1,
      microhangsGe250MsCount: 0, fullHangsGe500MsCount: 0,
      microhangsInNavWindow: 0, fullHangsInNavWindow: 0)
    #expect(compareTraceMetrics(overBody, baseline: baseline) == false)
  }

  @Test("Case (a): not-captured windowed metrics SKIP, run still passes")
  func notCapturedWindowedMetricsSkipGracefully() throws {
    let baseline = try JSONDecoder().decode(
      BaselineDocument.self, from: Data(Self.navHarnessBaselineJSON.utf8))
    // A trace with no signpost table: windowed counts nil, whole-trace + body
    // /unread still report. Body/unread under their ceilings → the run PASSES
    // (graceful degradation) rather than hard-failing on the missing window.
    let noSignpostTable = TraceMetrics(
      contentviewBodyGetterPct: 4, contentviewUnreadEntriesGetterPct: 0,
      sidebarNavGetterPct: 12,
      microhangsGe250MsCount: 7, fullHangsGe500MsCount: 2,
      microhangsInNavWindow: nil, fullHangsInNavWindow: nil)
    #expect(compareTraceMetrics(noSignpostTable, baseline: baseline) == true)
  }

  @Test("Null-max metrics decode as report-only, not as a zero ceiling")
  func nullMaxDecodesToNil() throws {
    let baseline = try JSONDecoder().decode(
      BaselineDocument.self, from: Data(Self.navHarnessBaselineJSON.utf8))
    #expect(baseline.level4Trace.microhangsGe250MsCount.max == nil)
    #expect(baseline.level4Trace.fullHangsGe500MsCount.max == nil)
    #expect(baseline.level4Trace.sidebarNavGetterPct?.max == nil)
    #expect(baseline.level4Trace.microhangsInNavWindow?.max == nil)
    #expect(baseline.level4Trace.fullHangsInNavWindow?.max == nil)
    // Active gates survive the schema change.
    #expect(baseline.level4Trace.contentviewBodyGetterPct.max == 9)
    #expect(baseline.level4Trace.contentviewUnreadEntriesGetterPct.max == 0.1)
  }

  // MARK: - Fixtures

  static let intervalRowSignpostXML = """
    <table schema="os-signpost">
      <row><start-time>1000</start-time><duration>5000</duration><name>perf-nav-window</name></row>
      <row><start-time>100</start-time><duration>50</duration><name>sidebar-click</name></row>
    </table>
    """

  static let beginEndSignpostXML = """
    <table schema="os-signpost">
      <row><event-type>Begin</event-type><start-time>2000</start-time><name>perf-nav-window</name></row>
      <row><event-type>End</event-type><start-time>7000</start-time><name>perf-nav-window</name></row>
    </table>
    """

  /// A healthy render trace: `perf-nav-window` [1000, 6000] plus a
  /// `sidebar-click` BEFORE the window (start 100 — the runner's pre-window
  /// priming nav) and one of each render signpost INSIDE the window.
  static let fullRenderSignpostXML = """
    <table schema="os-signpost">
      <row><start-time>1000</start-time><duration>5000</duration><name>perf-nav-window</name></row>
      <row><start-time>100</start-time><duration>20</duration><name>sidebar-click</name></row>
      <row><start-time>1200</start-time><duration>30</duration><name>sidebar-click</name></row>
      <row><start-time>2000</start-time><duration>40</duration><name>article-click</name></row>
      <row><start-time>2500</start-time><duration>100</duration><name>detail-render</name></row>
    </table>
    """

  /// A degenerate trace: `perf-nav-window` closed but the only render signpost
  /// (`sidebar-click`) fired BEFORE the window and nothing rendered inside it —
  /// the partial-render case the floor must reject.
  static let preWindowOnlySignpostXML = """
    <table schema="os-signpost">
      <row><start-time>1000</start-time><duration>5000</duration><name>perf-nav-window</name></row>
      <row><start-time>100</start-time><duration>20</duration><name>sidebar-click</name></row>
    </table>
    """

  /// A render signpost expressed as a Begin/End pair opening inside the window.
  static let beginEndRenderSignpostXML = """
    <table schema="os-signpost">
      <row><start-time>1000</start-time><duration>5000</duration><name>perf-nav-window</name></row>
      <row><event-type>Begin</event-type><start-time>1500</start-time><name>detail-render</name></row>
      <row><event-type>End</event-type><start-time>1800</start-time><name>detail-render</name></row>
    </table>
    """

  /// A zero-duration `article-click` interval — present but not a positive
  /// render, so the floor must reject it.
  static let zeroDurationRenderSignpostXML = """
    <table schema="os-signpost">
      <row><start-time>1000</start-time><duration>5000</duration><name>perf-nav-window</name></row>
      <row><start-time>2000</start-time><duration>0</duration><name>article-click</name></row>
    </table>
    """

  /// Hang durations in nanoseconds; start-times in the same base as the
  /// signpost window. Row 1: 300 ms @1500 (in), row 2: 600 ms @8000 (out),
  /// row 3: 550 ms @2000 (in), row 4: 260 ms @500 (out).
  static let hangsXML = """
    <table schema="potential-hangs">
      <row><start-time>1500</start-time><duration>300000000</duration></row>
      <row><start-time>8000</start-time><duration>600000000</duration></row>
      <row><start-time>2000</start-time><duration>550000000</duration></row>
      <row><start-time>500</start-time><duration>260000000</duration></row>
    </table>
    """

  static let timeProfileXML = """
    <table schema="time-profile">
      <row><weight>10</weight><backtrace>ContentView.body.getter</backtrace></row>
      <row><weight>8</weight><backtrace>ContentView.unreadEntries.getter</backtrace></row>
      <row><weight>6</weight><backtrace>sidebarNavigationItems(folderGroups:rootCategoryLabels:collapsedFolderLabels:)</backtrace></row>
      <row><weight>6</weight><backtrace>ContentView.visibleFolderGroups.getter</backtrace></row>
      <row><weight>70</weight><backtrace>someUnrelatedSymbol</backtrace></row>
    </table>
    """

  /// Mirror of the REAL `os-signpost` export: `<event-time>`/`<event-type>`/
  /// `<signpost-name>` columns with `id`/`ref` interning. The perf-nav-window
  /// End row (last) refs both its event-type (id 19 = End) and its name
  /// (id 23 = perf-nav-window); the sidebar-click End row refs its name
  /// (id 10). Resolving the window + floor requires following those refs.
  static let realSignpostXML = """
    <table schema="os-signpost">
      <row><event-time id="1" fmt="00:01">1000</event-time><event-type id="7" fmt="Begin">Begin</event-type><signpost-name id="23" fmt="perf-nav-window">perf-nav-window</signpost-name></row>
      <row><event-time id="2" fmt="00:06">6000</event-time><event-type ref="7"/><signpost-name id="10" fmt="sidebar-click">sidebar-click</signpost-name></row>
      <row><event-time id="3" fmt="00:06">6001</event-time><event-type id="19" fmt="End">End</event-type><signpost-name ref="10"/></row>
      <row><event-time id="4" fmt="00:18">18000</event-time><event-type ref="19"/><signpost-name ref="23"/></row>
    </table>
    """

  /// Mirror of the REAL aggregated `time-profile` export: `<weight>` and
  /// `<frame name="…">` with `id`/`ref` interning. Every sample after the
  /// first refs the 1.00 ms weight (id 9); sample 3 refs the ContentView frame
  /// (id 36). Both refs must resolve for the shares to come out right.
  static let realTimeProfileXML = """
    <table schema="time-profile">
      <row><weight id="9" fmt="1.00 ms">1000000</weight><tagged-backtrace id="10"><backtrace><frame id="36" name="closure #1 in ContentView.body.getter" addr="0x1"/><frame id="40" name="SwiftUI.dispatch" addr="0x2"/></backtrace></tagged-backtrace></row>
      <row><weight ref="9"/><tagged-backtrace id="11"><backtrace><frame id="50" name="Feeder.sidebarItems.getter" addr="0x3"/></backtrace></tagged-backtrace></row>
      <row><weight ref="9"/><tagged-backtrace id="12"><backtrace><frame ref="36"/></backtrace></tagged-backtrace></row>
      <row><weight ref="9"/><tagged-backtrace id="13"><backtrace><frame id="60" name="someUnrelatedSymbol" addr="0x4"/></backtrace></tagged-backtrace></row>
    </table>
    """

  /// Mirror of the `level4_trace` block after the nav-stutter harness landed:
  /// body/unread ceilings ACTIVE; every hang count + the sidebar-nav share
  /// report-only (null max) per Guard #1.
  static let navHarnessBaselineJSON = """
    {
      "captured_host_cpu" : "Apple M3",
      "captured_on" : "2026-07-08T00:00:00Z",
      "level2_signposts" : { "frame_budget_ms" : 8.3, "tolerance_pct" : 20 },
      "level4_trace" : {
        "contentview_body_getter_pct" : { "captured" : 0, "max" : 9 },
        "contentview_unread_entries_getter_pct" : { "captured" : 0, "max" : 0.1 },
        "full_hangs_ge_500ms_count" : { "captured" : 1, "max" : null },
        "full_hangs_in_nav_window" : { "captured" : null, "max" : null },
        "microhangs_ge_250ms_count" : { "captured" : 1, "max" : null },
        "microhangs_in_nav_window" : { "captured" : null, "max" : null },
        "sidebar_nav_getter_pct" : { "captured" : null, "max" : null }
      },
      "schema_version" : 1
    }
    """
}
