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
  /// The render-path signpost that must close at least once inside the nav
  /// window for a trace to count as a real render. It fires from the view layer
  /// on every selection commit and closes only when SwiftUI actually re-renders,
  /// whereas the nav window itself is emitted unconditionally and proves
  /// nothing about rendering.
  ///
  /// The article-side signposts are deliberately not required: the scenario
  /// emits them only when the article list has populated in time for a
  /// selection step, which races the reader refresh under write pressure, so
  /// gating on them makes the floor unsatisfiable.
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

    // Prefer the aggregated, symbolicated table over the raw sample table. Only
    // the aggregated one carries frame symbol names and per-sample weights,
    // which the percentage buckets need; the raw one holds address-only
    // backtraces and yields all-zero shares.
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

    // Four distinct outcomes, deliberately not collapsed: the central risk is
    // blessing a stale-binary or a non-rendering trace as green.
    //
    // No signpost table at all means the template recorded no signposts.
    // Degrade gracefully: the window is nil and the windowed metrics skip,
    // while the whole-trace metrics still report. Throwing here would make the
    // harness unusable on a host whose template does not capture signposts.
    //
    // A signpost table with no nav-window interval is the dangerous case: the
    // launch almost certainly resolved to a stale build that emits older
    // signposts. Fail loud, because a stale-code trace must never pass.
    //
    // A nav window with no closed render-path signpost inside it means nothing
    // rendered: the window is emitted unconditionally and closes even when the
    // list never rendered a row. Fail loud, or a partial-render run passes.
    //
    // A nav window that meets the render-path floor windows the hang counts.
    let window: (start: Double, end: Double)?
    if !hasSignpost {
      window = nil
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
      // Parse the signpost rows once: the window resolution and the
      // render-path floor read the same export.
      let rows = parseSignpostRows(xml: signpostXML)
      guard let resolved = resolveInterval(rows: rows, name: "perf-nav-window") else {
        // No nav window at all. Check the total-activation failure before the
        // stale-binary cause, so a broken activation delegate does not send the
        // reader off to clear derived data for nothing.
        throw PerfParserError(
          message: "trace \(traceURL.lastPathComponent) has an os_signpost table but no resolvable "
            + "`perf-nav-window` interval — the perf scenario never reached `beginInterval`. Two "
            + "causes, check in THIS order: (1) a TOTAL activation failure under headless launch "
            + "(#132) — the perf launch never brought a live, rendering window on screen, so "
            + "`ContentView.runPerfScenario()` never fired: confirm the activation delegate fired "
            + "and a foreground window was activated (a LOCAL interactive GUI session is required) "
            + "BEFORE assuming a stale binary or clearing DerivedData; (2) a WRONG/STALE binary — "
            + "LaunchServices resolved the launch to a different `com.feeder.app` build (a stale "
            + "Xcode DerivedData Debug build) that emits older signposts but not `perf-nav-window`: "
            + "clear the stale registration (rm -rf ~/Library/Developer/Xcode/DerivedData/Feeder-*) "
            + "and re-run. Refusing to report windowed metrics against a trace with no nav window."
        )
      }
      // The measured nav path must have rendered inside the window. One closed,
      // positive-duration render-path occurrence is the reliable witness that
      // SwiftUI committed a selection and re-rendered, which the window alone
      // does not prove.
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
      window = resolved
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

  /// Parse an os-signpost export into raw rows. Split out so the window
  /// resolution and the render-path floor share one parse of the same export.
  static func parseSignpostRows(xml: Data) -> [SignpostRow] {
    let handler = SignpostRowHandler()
    let parser = XMLParser(data: xml)
    parser.delegate = handler
    guard parser.parse() else { return [] }
    return handler.rows
  }

  /// True when `rows` carries a closed, positive-duration interval named `name`
  /// whose start falls inside `window`. A render-path signpost closes only when
  /// the view layer rendered, so one closed occurrence inside the measured
  /// window witnesses a real render under load.
  ///
  /// It must scan every matching row, not the first: the runner fires one such
  /// signpost from its priming step before the window opens, so a first-match
  /// resolver would reject a healthy run.
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
/// Like the signpost export, this one interns repeated values: a frame seen
/// before appears as a ref, and so does a repeated weight. Every ref must be
/// resolved against the interning tables, or most samples lose their symbols
/// and all but the first lose their weight, which skews every share. Plain
/// inline text is still accepted for hand-built fixtures.
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
/// The real export names its columns event-time, event-type and signpost-name,
/// and interns repeated values: the first occurrence carries an id plus the
/// value, and every later one is a self-closing ref. A begin or end row almost
/// always refs its type and name, so every ref must be resolved against the
/// interning table, or the interval name and phase come back empty and no
/// window resolves. The synthetic inline shapes are still accepted for
/// hand-built fixtures.
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

  // Active gates, with a populated maximum: the architectural invariants that
  // must keep holding, so a regression in the body or unread path fails here.
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
  // Report-only: the sidebar-nav share and the hang counts carry a null
  // maximum, so they skip rather than gate.
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
  // Windowed hang counts skip with their own reason when the metric was not
  // captured at all, which is distinct from the report-only skip.
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
