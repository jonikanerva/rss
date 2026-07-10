import Foundation

// MARK: - Level 4 trace metrics

struct TraceMetrics {
  var contentviewBodyGetterPct: Double
  var contentviewUnreadEntriesGetterPct: Double
  /// Inclusive main-thread sample share of the sidebar-nav recompute symbols
  /// (`sidebarItems` / `visibleFolderGroups` / `sidebarNavigationItems`) —
  /// the per-keystroke work J/K triggers. High share under load points at the
  /// nav path as the stutter source.
  var sidebarNavGetterPct: Double
  /// Whole-trace hang counts (include the once-per-launch cold-start hang).
  var microhangsGe250MsCount: Int
  var fullHangsGe500MsCount: Int
  /// Hang counts windowed to the `perf-nav-window` signpost interval — the
  /// readable under-load stutter signal with cold start excluded. `nil` when
  /// the trace carries no os_signpost table at all (the template did not
  /// record signposts): the windowed metrics degrade to "not captured" (SKIP)
  /// rather than failing the run. A trace that HAS a signpost table but no
  /// `perf-nav-window` interval never reaches here — that is the wrong/stale
  /// binary case and `extractMetrics` throws loudly.
  var microhangsInNavWindow: Int?
  var fullHangsInNavWindow: Int?
}

/// Drives `xctrace export` against every `.trace` bundle in the given
/// directory, parses the per-iteration metrics, and returns the median
/// across iterations. Fails closed on missing schemas or empty output —
/// `make perf` must never declare a silent green.
enum TraceMetricsAggregator {
  /// The render-path signpost that must have at least one closed occurrence
  /// inside `perf-nav-window` for a trace to count as a real render (the
  /// non-degeneracy floor, issue #132). `sidebar-click` fires from the view
  /// layer on EVERY J/K selection commit → content-column re-render task (see
  /// `Feeder/Helpers/PerformanceSignposts.swift`), so it appears ~17-18× inside
  /// the window and closes ONLY when SwiftUI actually commits a selection and
  /// re-renders. `perf-nav-window` itself is emitted unconditionally by
  /// `PerfScenarioRunner.run`, so it is NOT proof that anything rendered;
  /// `sidebar-click` is.
  ///
  /// `article-click` / `detail-render` are intentionally NOT required. The
  /// scenario emits them only when the middle-pane article LIST has populated
  /// in time for an article-selection step, which races the `DataReader`
  /// refresh under write pressure and does not fire on a fresh-seeded launch —
  /// every deterministic iteration emits ZERO of them. Gating on them made the
  /// floor unsatisfiable. The article-list under-population is a separate,
  /// pre-existing scenario limitation (the runner is out of this change's
  /// scope); it is tracked as a follow-up so the middle-pane render can be
  /// re-exercised without weakening this gate.
  static let requiredRenderSignpostName = "sidebar-click"

  static func run(traceDir: String) throws -> TraceMetrics {
    let url = URL(fileURLWithPath: traceDir)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
      throw PerfParserError(message: "trace directory not found at \(traceDir)")
    }
    let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    let traces = entries.filter { $0.pathExtension == "trace" }.sorted { $0.path < $1.path }
    guard !traces.isEmpty else {
      throw PerfParserError(
        message: "no .trace bundles found in \(traceDir); did `xctrace record` run?"
      )
    }

    var bodyPcts: [Double] = []
    var unreadPcts: [Double] = []
    var sidebarNavPcts: [Double] = []
    var microhangs: [Int] = []
    var fullHangs: [Int] = []
    var microhangsInWindow: [Int] = []
    var fullHangsInWindow: [Int] = []

    for trace in traces {
      let m = try extractMetrics(traceURL: trace)
      bodyPcts.append(m.contentviewBodyGetterPct)
      unreadPcts.append(m.contentviewUnreadEntriesGetterPct)
      sidebarNavPcts.append(m.sidebarNavGetterPct)
      microhangs.append(m.microhangsGe250MsCount)
      fullHangs.append(m.fullHangsGe500MsCount)
      // Windowed counts are absent (nil) for traces without a signpost table;
      // only the captured ones feed the median. If NO iteration captured a
      // window, the aggregate stays nil → the metric reports as SKIP.
      if let micro = m.microhangsInNavWindow { microhangsInWindow.append(micro) }
      if let full = m.fullHangsInNavWindow { fullHangsInWindow.append(full) }
    }

    return TraceMetrics(
      contentviewBodyGetterPct: bodyPcts.median() ?? 0,
      contentviewUnreadEntriesGetterPct: unreadPcts.median() ?? 0,
      sidebarNavGetterPct: sidebarNavPcts.median() ?? 0,
      microhangsGe250MsCount: medianInt(microhangs),
      fullHangsGe500MsCount: medianInt(fullHangs),
      microhangsInNavWindow: microhangsInWindow.isEmpty ? nil : medianInt(microhangsInWindow),
      fullHangsInNavWindow: fullHangsInWindow.isEmpty ? nil : medianInt(fullHangsInWindow)
    )
  }

  // MARK: - Per-trace extraction

  static func extractMetrics(traceURL: URL) throws -> TraceMetrics {
    // 1. Confirm the expected schemas are present.
    let toc = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: ["xctrace", "export", "--input", traceURL.path, "--toc"]
    )
    let tocXML = String(data: toc, encoding: .utf8) ?? ""
    let hasTimeProfile =
      tocXML.contains("schema=\"time-profile\"")
      || tocXML.contains("schema=\"time-sample\"")
    let hasHangs =
      tocXML.contains("schema=\"potential-hangs\"")
      || tocXML.contains("schema=\"hang-events\"")
    let hasSignpost =
      tocXML.contains("schema=\"os-signpost\"")
      || tocXML.contains("schema=\"points-of-interest\"")
    guard hasTimeProfile else {
      throw PerfParserError(
        message: "trace \(traceURL.lastPathComponent) is missing time-profile schema; "
          + "re-record with the Time Profiler template (xctrace record --template 'Time Profiler')"
      )
    }
    guard hasHangs else {
      throw PerfParserError(
        message: "trace \(traceURL.lastPathComponent) is missing potential-hangs schema; "
          + "re-record with the Time Profiler template, which includes Hangs"
      )
    }

    // Prefer the AGGREGATED, SYMBOLICATED `time-profile` table over the raw
    // `time-sample` table. Only `time-profile` carries `<frame name="…">`
    // symbol names and per-sample `<weight>`, which the getter-percentage
    // buckets need. `time-sample` holds address-only `kperf-bt` backtraces (no
    // symbols), so parsing it yields all-zero shares — the reason the parser
    // reported 0 % on real traces before this was fixed (issue #132).
    let schemaName = tocXML.contains("schema=\"time-profile\"") ? "time-profile" : "time-sample"
    let hangSchema =
      tocXML.contains("schema=\"hang-events\"")
      ? "hang-events" : "potential-hangs"

    let timeXML = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xctrace", "export", "--input", traceURL.path,
        "--xpath", "/trace-toc/run/data/table[@schema=\"\(schemaName)\"]",
      ]
    )
    let shares = try parseTimeProfile(xml: timeXML)

    let hangsXML = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xctrace", "export", "--input", traceURL.path,
        "--xpath", "/trace-toc/run/data/table[@schema=\"\(hangSchema)\"]",
      ]
    )
    let hangEvents = try parseHangEvents(xml: hangsXML)

    // Signpost-window resolution — four distinct outcomes, deliberately NOT
    // collapsed (the taxonomy is load-bearing: the central risk is never
    // blessing a stale/wrong-binary OR a non-rendering trace as green):
    //
    // (a) NO os_signpost table at all → the template did not record signposts.
    //     Degrade gracefully: window is nil, windowed metrics report SKIP,
    //     whole-trace metrics + sidebar_nav still report, the run does NOT
    //     fail. Hard-throwing here would make the harness unusable on a clean
    //     host whose template happens not to capture signposts.
    // (b) os_signpost table PRESENT but the `perf-nav-window` interval ABSENT
    //     → the dangerous case: LaunchServices almost certainly resolved the
    //     launch to a stale/wrong `com.feeder.app` build that emits older
    //     signposts (e.g. `sidebar-click`) but not `perf-nav-window`. Fail
    //     LOUD — a stale-code trace must never pass as green.
    // (d) `perf-nav-window` present but the render/nav path is EMPTY — none of
    //     the render-path signposts closed inside the window. `perf-nav-window`
    //     is emitted directly by `PerfScenarioRunner.run`, so it closes even if
    //     the List never rendered a row; the render-path signposts close ONLY
    //     when the view-layer `.task`/render fires. Their absence means the
    //     window never rendered (e.g. forced activation failed to bring a live
    //     window on screen). Fail LOUD — a green here would be a false pass on
    //     a partial-render run (issue #132, non-degeneracy floor).
    // (c) table present WITH `perf-nav-window` AND the render-path floor met →
    //     window the hang counts.
    let window: (start: Double, end: Double)?
    if !hasSignpost {
      window = nil  // (a)
    } else {
      let signpostSchema =
        tocXML.contains("schema=\"os-signpost\"")
        ? "os-signpost" : "points-of-interest"
      let signpostXML = try runProcess(
        launchPath: "/usr/bin/xcrun",
        arguments: [
          "xctrace", "export", "--input", traceURL.path,
          "--xpath", "/trace-toc/run/data/table[@schema=\"\(signpostSchema)\"]",
        ]
      )
      // Parse the signpost rows once — both the window resolution and the
      // render-path floor read the same export.
      let rows = parseSignpostRows(xml: signpostXML)
      guard let resolved = resolveInterval(rows: rows, name: "perf-nav-window") else {
        // (b) — refuse to report against a stale trace.
        throw PerfParserError(
          message: "trace \(traceURL.lastPathComponent) has an os_signpost table but no resolvable "
            + "`perf-nav-window` interval. xctrace almost certainly traced the WRONG/STALE binary: "
            + "LaunchServices resolved the launch to a different `com.feeder.app` build (a stale "
            + "Xcode DerivedData Debug build) that emits older signposts but not `perf-nav-window`. "
            + "Refusing to report windowed metrics against a stale trace. Clear the stale "
            + "registration (rm -rf ~/Library/Developer/Xcode/DerivedData/Feeder-*) and re-run, or "
            + "confirm PerfScenarioRunner reached the end of the nav walk before exit."
        )
      }
      // (d) Non-degeneracy floor: the measured nav path must have actually
      // rendered inside the window. Require at least one closed, positive-
      // duration `sidebar-click` occurrence inside the window — it is the
      // reliable witness that SwiftUI committed a selection and re-rendered,
      // which `perf-nav-window` alone (emitted unconditionally by the runner)
      // does not prove. Distinct from (b): here the window WAS resolvable.
      guard
        hasRenderSignpostInWindow(
          rows: rows, name: Self.requiredRenderSignpostName, window: resolved)
      else {
        throw PerfParserError(
          message: "trace \(traceURL.lastPathComponent): `perf-nav-window` is present but no "
            + "`\(Self.requiredRenderSignpostName)` render witness closed inside the window — the "
            + "measured nav path did NOT render. `perf-nav-window` is emitted directly by "
            + "PerfScenarioRunner.run, so it closes even if nothing on screen re-rendered; "
            + "`sidebar-click` closes ONLY when SwiftUI commits a selection and the content column "
            + "re-renders. Its absence means the perf launch did not bring a live, rendering "
            + "surface on screen (a LOCAL interactive GUI session is required). This is DISTINCT "
            + "from the stale/wrong-binary case — the `perf-nav-window` interval WAS resolvable. "
            + "Confirm the perf launch activated a foreground window and re-run (issue #132)."
        )
      }
      window = resolved  // (c)
    }

    let counts = countHangs(hangEvents, window: window)

    return TraceMetrics(
      contentviewBodyGetterPct: shares.bodyPct,
      contentviewUnreadEntriesGetterPct: shares.unreadPct,
      sidebarNavGetterPct: shares.sidebarNavPct,
      microhangsGe250MsCount: counts.micro,
      fullHangsGe500MsCount: counts.full,
      microhangsInNavWindow: counts.microInWindow,
      fullHangsInNavWindow: counts.fullInWindow
    )
  }

  // MARK: - Time-profile parsing

  struct TimeProfileShares {
    var bodyPct: Double
    var unreadPct: Double
    var sidebarNavPct: Double
  }

  /// Parse a time-profile / time-sample export. Sums per-frame sample weights
  /// that name the hot symbols and divides by the total sample weight to
  /// produce an inclusive sample percentage per symbol bucket.
  static func parseTimeProfile(xml: Data) throws -> TimeProfileShares {
    let handler = TimeProfileSampleHandler()
    let parser = XMLParser(data: xml)
    parser.delegate = handler
    if !parser.parse() {
      throw PerfParserError(
        message:
          "failed to parse time-profile XML: \(parser.parserError?.localizedDescription ?? "<no error>")"
      )
    }
    let total = handler.totalWeight
    guard total > 0 else {
      throw PerfParserError(message: "time-profile contained zero samples")
    }
    return TimeProfileShares(
      bodyPct: handler.bodyWeight / total * 100.0,
      unreadPct: handler.unreadWeight / total * 100.0,
      sidebarNavPct: handler.sidebarNavWeight / total * 100.0
    )
  }

  // MARK: - Signpost window parsing

  /// Resolve the `[start, end]` of the named signpost interval from an
  /// os-signpost / points-of-interest export. Handles two export shapes:
  /// an interval row carrying both a start-time and a duration, or a
  /// Begin/End event pair. Returns `nil` when the interval cannot be resolved.
  /// Times are the raw values from the export (nanoseconds since trace start
  /// in the modern schema) — the same base as hang start-times, so the two
  /// are directly comparable without unit conversion.
  static func parseSignpostWindow(xml: Data, name: String) -> (start: Double, end: Double)? {
    resolveInterval(rows: parseSignpostRows(xml: xml), name: name)
  }

  /// Parse an os-signpost / points-of-interest export into raw signpost rows.
  /// Split out so the window resolution and the render-path floor (issue #132)
  /// share a single parse of the same export.
  static func parseSignpostRows(xml: Data) -> [SignpostRow] {
    let handler = SignpostRowHandler()
    let parser = XMLParser(data: xml)
    parser.delegate = handler
    guard parser.parse() else { return [] }
    return handler.rows
  }

  /// True when `rows` carries a CLOSED, positive-duration interval named `name`
  /// whose start falls inside `window`. The render-path floor's per-signpost
  /// check (issue #132): the render-path signposts only CLOSE when the view
  /// layer actually rendered, so one closed occurrence inside the measured
  /// window witnesses that a real render happened under load.
  ///
  /// Scans EVERY matching row, not just the first: `PerfScenarioRunner` fires
  /// one `sidebar-click` from its pre-window `navigate(.next)` priming step —
  /// BEFORE `perf-nav-window` opens — so a first-match resolver would reject a
  /// healthy run. A later in-window occurrence still satisfies the floor.
  static func hasRenderSignpostInWindow(
    rows: [SignpostRow], name: String, window: (start: Double, end: Double)
  ) -> Bool {
    // Interval-row shape: one row carrying both start-time and duration.
    for row in rows where row.name.contains(name) {
      if let start = row.time, let duration = row.duration, duration > 0,
        start >= window.start, start <= window.end
      {
        return true
      }
    }
    // Begin/End pair shape: a Begin inside the window matched to a later End.
    let matching = rows.filter { $0.name.contains(name) }
    let begins = matching.filter {
      ($0.phase?.lowercased().contains("begin") ?? false) && $0.time != nil
    }
    let ends = matching.filter {
      ($0.phase?.lowercased().contains("end") ?? false) && $0.time != nil
    }
    for begin in begins {
      guard let start = begin.time, start >= window.start, start <= window.end else { continue }
      if ends.contains(where: { ($0.time ?? -1) > start }) {
        return true
      }
    }
    return false
  }

  /// Pure resolver, split out so it is unit-testable on hand-built rows.
  static func resolveInterval(
    rows: [SignpostRow], name: String
  ) -> (start: Double, end: Double)? {
    let matching = rows.filter { $0.name.contains(name) }
    // Preferred shape: an interval row with start + duration.
    if let interval = matching.first(where: { $0.time != nil && $0.duration != nil }),
      let start = interval.time, let duration = interval.duration
    {
      return (start, start + duration)
    }
    // Fallback shape: a Begin event followed by an End event.
    let begin = matching.first { ($0.phase?.lowercased().contains("begin") ?? false) && $0.time != nil }
    let end = matching.last { ($0.phase?.lowercased().contains("end") ?? false) && $0.time != nil }
    if let start = begin?.time, let stop = end?.time, stop >= start {
      return (start, stop)
    }
    return nil
  }

  // MARK: - Hang parsing

  /// One potential-hang / hang-event row. `startTime` is the raw export value
  /// (same base as the signpost window) so windowing is a direct compare.
  struct HangEvent {
    var startTime: Double?
    var durationMs: Double
  }

  /// Parse hang rows into events carrying both a start-time and a duration.
  static func parseHangEvents(xml: Data) throws -> [HangEvent] {
    let handler = HangsHandler()
    let parser = XMLParser(data: xml)
    parser.delegate = handler
    if !parser.parse() {
      throw PerfParserError(
        message:
          "failed to parse hangs XML: \(parser.parserError?.localizedDescription ?? "<no error>")"
      )
    }
    return handler.events
  }

  /// Count hangs at the 250 ms (micro) and 500 ms (full) thresholds, both
  /// whole-trace and windowed to the given signpost interval. A hang counts as
  /// in-window when its start-time falls inside `[window.start, window.end]`.
  ///
  /// When `window` is `nil` (no signpost table — case (a) in `extractMetrics`),
  /// the windowed counts are returned as `nil` ("not captured"), NOT `0` — a
  /// zero would falsely read as "no stutter in the window". The whole-trace
  /// counts are always returned.
  static func countHangs(
    _ events: [HangEvent], window: (start: Double, end: Double)?
  ) -> (micro: Int, full: Int, microInWindow: Int?, fullInWindow: Int?) {
    var micro = 0
    var full = 0
    var microInWindow = 0
    var fullInWindow = 0
    for event in events {
      let isMicro = event.durationMs >= 250
      let isFull = event.durationMs >= 500
      if isMicro { micro += 1 }
      if isFull { full += 1 }
      if let window, let start = event.startTime,
        start >= window.start, start <= window.end
      {
        if isMicro { microInWindow += 1 }
        if isFull { fullInWindow += 1 }
      }
    }
    guard window != nil else { return (micro, full, nil, nil) }
    return (micro, full, microInWindow, fullInWindow)
  }
}

// MARK: - Integer median

func medianInt(_ values: [Int]) -> Int {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let mid = sorted.count / 2
  if sorted.count.isMultiple(of: 2) {
    return (sorted[mid - 1] + sorted[mid]) / 2
  }
  return sorted[mid]
}

// MARK: - XML handlers

/// SAX-style handler for `xctrace`'s aggregated `time-profile` export. Each
/// `<row>` is one weighted sample: `<weight>` (nanoseconds) plus a
/// `<tagged-backtrace>` of `<frame name="…">` symbols. We sum the weight of
/// every sample whose backtrace names a hot symbol and divide by the total so
/// the result is the inclusive share of main-thread time the symbol consumed.
///
/// Like the signpost export, `time-profile` INTERNS repeated values: a frame
/// seen before appears as `<frame ref="N"/>` and a repeated weight as
/// `<weight ref="N"/>`. Refs MUST be resolved against the interning tables, or
/// most samples lose their symbols (and all but the first lose their weight),
/// skewing every share (issue #132). Plain `<weight>` + `<backtrace>` text is
/// still accepted for hand-built test fixtures.
final class TimeProfileSampleHandler: NSObject, XMLParserDelegate {
  var totalWeight: Double = 0
  var bodyWeight: Double = 0
  var unreadWeight: Double = 0
  var sidebarNavWeight: Double = 0

  /// `id` → frame symbol name, for resolving `<frame ref="N"/>`.
  private var internedFrame: [String: String] = [:]
  /// `id` → sample weight, for resolving `<weight ref="N"/>`.
  private var internedWeight: [String: Double] = [:]

  private var currentSampleSymbols: [String] = []
  private var characterBuffer: String = ""
  private var currentWeight: Double = 0
  private var currentWeightID: String?

  func parser(
    _ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    characterBuffer = ""
    if elementName == "row" || elementName == "sample" {
      currentSampleSymbols = []
      currentWeight = 0
      return
    }
    if elementName == "frame" {
      // Defining frame: `<frame id="N" name="…">`. Repeat: `<frame ref="N"/>`.
      if let id = attributeDict["id"], let name = attributeDict["name"], !name.isEmpty {
        internedFrame[id] = name
        currentSampleSymbols.append(name)
      } else if let ref = attributeDict["ref"], let name = internedFrame[ref] {
        currentSampleSymbols.append(name)
      } else if let name = attributeDict["name"], !name.isEmpty {
        currentSampleSymbols.append(name)
      }
    } else if elementName == "weight" {
      // Defining weight carries id + text; a repeat is `<weight ref="N"/>`.
      currentWeightID = attributeDict["id"]
      if let ref = attributeDict["ref"], let value = internedWeight[ref] {
        currentWeight = value
      }
    } else if let name = attributeDict["name"], !name.isEmpty {
      // Fallback for other exports that inline a symbol as a `name` attribute.
      currentSampleSymbols.append(name)
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    characterBuffer.append(string)
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?
  ) {
    let trimmed = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "frame", "backtrace":
      if !trimmed.isEmpty {
        currentSampleSymbols.append(trimmed)
      }
    case "weight", "sample-time", "duration":
      if let value = Double(trimmed) {
        currentWeight = value
        if let id = currentWeightID { internedWeight[id] = value }
      }
      currentWeightID = nil
    case "row", "sample":
      let weight = currentWeight > 0 ? currentWeight : 1
      totalWeight += weight
      let symbols = currentSampleSymbols.joined(separator: " ")
      if symbols.contains("ContentView") && symbols.contains("body") {
        bodyWeight += weight
      }
      if symbols.contains("ContentView") && symbols.contains("unreadEntries") {
        unreadWeight += weight
      }
      if symbols.contains("sidebarItems")
        || symbols.contains("visibleFolderGroups")
        || symbols.contains("sidebarNavigationItems")
      {
        sidebarNavWeight += weight
      }
      currentSampleSymbols = []
      currentWeight = 0
    default:
      break
    }
    characterBuffer = ""
  }
}

/// A raw signpost row: a name plus whatever time / duration / phase fields the
/// export carried. `TraceMetricsAggregator.resolveInterval` turns matching
/// rows into a `[start, end]` window.
struct SignpostRow {
  var name: String
  var time: Double?
  var duration: Double?
  var phase: String?
}

/// SAX-style handler for the os-signpost / points-of-interest export. Collects
/// one `SignpostRow` per `<row>` — the resolver picks the matching interval.
///
/// The real `xctrace` export names the columns `<event-time>` (nanoseconds),
/// `<event-type>` (`Begin`/`End`), and `<signpost-name>`. It also INTERNS
/// repeated values: the first occurrence of a value carries `id="N"` plus the
/// value (element text, or the `fmt` attribute), and every later occurrence is
/// a self-closing `<element ref="N"/>`. Begin/End rows almost always ref their
/// `event-type` and `signpost-name`, so refs MUST be resolved against the
/// interning table — otherwise the interval name and phase come back empty and
/// no window resolves (issue #132; the pre-fix handler read `<name>` and
/// ignored refs, so it never parsed a real trace). The synthetic `<name>` /
/// `<start-time>` / `<duration>` shapes are still accepted for hand-built test
/// fixtures.
final class SignpostRowHandler: NSObject, XMLParserDelegate {
  var rows: [SignpostRow] = []
  private var characterBuffer: String = ""

  /// Interning table: `id` → resolved value (element text preferred; the `fmt`
  /// attribute as a fallback). Shared across the whole table so a later
  /// `ref="N"` recovers the value defined earlier.
  private var interned: [String: String] = [:]
  private var currentID: String?

  // Current-row accumulation.
  private var inRow = false
  private var name: String = ""
  private var time: Double?
  private var duration: Double?
  private var phase: String?

  private static let timeElements: Set<String> = [
    "event-time", "start-time", "sample-time", "time",
  ]
  private static let nameElements: Set<String> = [
    "signpost-name", "os-signpost-name", "name",
  ]
  private static let phaseElements: Set<String> = ["event-type", "phase"]

  func parser(
    _ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    characterBuffer = ""
    currentID = attributeDict["id"]
    if elementName == "row" {
      inRow = true
      name = ""
      time = nil
      duration = nil
      phase = nil
      return
    }
    guard inRow else { return }
    // A `ref` recovers a previously-interned value (self-closing, no text).
    if let ref = attributeDict["ref"], let value = interned[ref] {
      assign(elementName, value)
    }
    // A defining occurrence may carry its value in `fmt`; record + assign it
    // now, and let element text (if present) override in `didEndElement`.
    if let id = attributeDict["id"], let fmt = attributeDict["fmt"] {
      interned[id] = fmt
      assign(elementName, fmt)
    }
    // Duration, when present, is a plain attribute on interval-row fixtures.
    if let durationAttr = attributeDict["duration"], let value = Double(durationAttr) {
      duration = value
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    characterBuffer.append(string)
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?
  ) {
    let trimmed = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if inRow, !trimmed.isEmpty {
      if let id = currentID { interned[id] = trimmed }  // text is authoritative
      if elementName == "duration", let value = Double(trimmed) {
        duration = value
      } else {
        assign(elementName, trimmed)
      }
      // Some exports carry the interval name only as the row's message text.
      if name.isEmpty, trimmed.contains("perf-nav-window") {
        name = trimmed
      }
    }
    if elementName == "row", inRow {
      rows.append(SignpostRow(name: name, time: time, duration: duration, phase: phase))
      inRow = false
    }
    characterBuffer = ""
    currentID = nil
  }

  /// Route a resolved value into the row field its element name maps to. A
  /// non-numeric time value (e.g. the `fmt` string `00:06.231`) simply fails
  /// the `Double` parse and leaves `time` for the authoritative element text.
  private func assign(_ element: String, _ value: String) {
    if Self.timeElements.contains(element) {
      if let parsed = Double(value) { time = parsed }
    } else if Self.phaseElements.contains(element) {
      phase = value
    } else if Self.nameElements.contains(element) {
      name = value
    }
  }
}

/// SAX-style handler for the `potential-hangs` / `hang-events` export. Reads
/// both the `duration` field (nanoseconds in the modern schema; falls back to
/// seconds when the value looks too small) and the hang's start-time so the
/// aggregator can window the count to the nav interval.
final class HangsHandler: NSObject, XMLParserDelegate {
  var events: [TraceMetricsAggregator.HangEvent] = []
  private var characterBuffer: String = ""
  private var durationText: String = ""
  private var startTime: Double?
  private var inRow = false

  private static let timeElements: Set<String> = [
    "start-time", "sample-time", "event-time", "time",
  ]

  func parser(
    _ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    characterBuffer = ""
    if elementName == "row" || elementName == "hang" {
      inRow = true
      durationText = ""
      startTime = nil
    }
    guard inRow else { return }
    if let durationStr = attributeDict["duration"], !durationStr.isEmpty {
      durationText = durationStr
    }
    for key in Self.timeElements {
      if let value = attributeDict[key], let parsed = Double(value) {
        startTime = parsed
      }
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    characterBuffer.append(string)
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?
  ) {
    let trimmed = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if inRow, !trimmed.isEmpty {
      if elementName == "duration" {
        durationText = trimmed
      } else if Self.timeElements.contains(elementName), let value = Double(trimmed) {
        startTime = value
      }
    }
    if elementName == "row" || elementName == "hang" {
      if let durationNs = Double(durationText.trimmingCharacters(in: .whitespacesAndNewlines)) {
        // xctrace defaults to nanoseconds; if the value looks too small,
        // assume seconds and scale up.
        let durationMs = durationNs >= 1_000_000 ? durationNs / 1_000_000 : durationNs * 1000
        events.append(
          TraceMetricsAggregator.HangEvent(startTime: startTime, durationMs: durationMs))
      }
      inRow = false
      durationText = ""
      startTime = nil
    }
    characterBuffer = ""
  }
}

// MARK: - Reporting

func printTraceMetrics(_ metrics: TraceMetrics) {
  print(String(format: "  contentview_body_getter_pct: %.2f%%", metrics.contentviewBodyGetterPct))
  print(
    String(
      format: "  contentview_unread_entries_getter_pct: %.2f%%",
      metrics.contentviewUnreadEntriesGetterPct
    )
  )
  print(String(format: "  sidebar_nav_getter_pct: %.2f%%", metrics.sidebarNavGetterPct))
  print("  microhangs_ge_250ms_count (whole trace): \(metrics.microhangsGe250MsCount)")
  print("  full_hangs_ge_500ms_count (whole trace): \(metrics.fullHangsGe500MsCount)")
  func windowed(_ value: Int?) -> String {
    value.map(String.init) ?? "<not captured — no signpost table>"
  }
  print("  microhangs_in_nav_window: \(windowed(metrics.microhangsInNavWindow))")
  print("  full_hangs_in_nav_window: \(windowed(metrics.fullHangsInNavWindow))")
}

func compareTraceMetrics(_ metrics: TraceMetrics, baseline: BaselineDocument) -> Bool {
  var allPass = true

  /// Compare against a `ThresholdMetric` whose `max` may be null (report-only
  /// SKIP) — mirrors the Level 1 / Level 2 SKIP-on-null contract. `capturedFmt`
  /// renders just the captured value for the SKIP line; `compareFmt` renders
  /// the `captured vs threshold` line for PASS/FAIL.
  func compareOptional(
    name: String, captured: Double, metric: ThresholdMetric?,
    capturedFmt: String, compareFmt: String
  ) {
    guard let metric, let threshold = metric.max else {
      print(
        "SKIP  \(name): baseline max is null (report-only) — captured "
          + String(format: capturedFmt, captured))
      return
    }
    let line = String(format: compareFmt, captured, threshold)
    if captured > threshold {
      print("FAIL  \(name): \(line)")
      allPass = false
    } else {
      print("PASS  \(name): \(line)")
    }
  }

  // Active gates (max populated): the architectural invariants the perf fix
  // established. These stay live so a regression in the body / unread path
  // still fails the gate in the interim.
  compareOptional(
    name: "contentview_body_getter_pct",
    captured: metrics.contentviewBodyGetterPct,
    metric: baseline.level4Trace.contentviewBodyGetterPct,
    capturedFmt: "%.2f%%", compareFmt: "%.2f%% vs threshold %.2f%%"
  )
  compareOptional(
    name: "contentview_unread_entries_getter_pct",
    captured: metrics.contentviewUnreadEntriesGetterPct,
    metric: baseline.level4Trace.contentviewUnreadEntriesGetterPct,
    capturedFmt: "%.2f%%", compareFmt: "%.2f%% vs threshold %.2f%%"
  )
  // Report-only until the real fix is Time-Profiler-verified (Guard #1): the
  // sidebar-nav share and every hang count ship with a null max so they SKIP.
  compareOptional(
    name: "sidebar_nav_getter_pct",
    captured: metrics.sidebarNavGetterPct,
    metric: baseline.level4Trace.sidebarNavGetterPct,
    capturedFmt: "%.2f%%", compareFmt: "%.2f%% vs threshold %.2f%%"
  )
  compareOptional(
    name: "microhangs_ge_250ms_count",
    captured: Double(metrics.microhangsGe250MsCount),
    metric: baseline.level4Trace.microhangsGe250MsCount,
    capturedFmt: "%.0f", compareFmt: "%.0f vs threshold %.0f"
  )
  compareOptional(
    name: "full_hangs_ge_500ms_count",
    captured: Double(metrics.fullHangsGe500MsCount),
    metric: baseline.level4Trace.fullHangsGe500MsCount,
    capturedFmt: "%.0f", compareFmt: "%.0f vs threshold %.0f"
  )
  // Windowed hang counts: SKIP with a distinct reason when the metric was not
  // captured (no signpost table — case (a) in extractMetrics), separate from
  // the report-only null-max SKIP.
  func compareWindowed(name: String, captured: Int?, metric: ThresholdMetric?) {
    guard let captured else {
      print(
        "SKIP  \(name): not captured — trace carried no os_signpost table, so the "
          + "perf-nav-window interval could not be resolved (end-to-end windowing unverified)")
      return
    }
    compareOptional(
      name: name, captured: Double(captured), metric: metric,
      capturedFmt: "%.0f", compareFmt: "%.0f vs threshold %.0f")
  }
  compareWindowed(
    name: "microhangs_in_nav_window",
    captured: metrics.microhangsInNavWindow,
    metric: baseline.level4Trace.microhangsInNavWindow
  )
  compareWindowed(
    name: "full_hangs_in_nav_window",
    captured: metrics.fullHangsInNavWindow,
    metric: baseline.level4Trace.fullHangsInNavWindow
  )
  return allPass
}
