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
  /// readable under-load stutter signal with cold start excluded.
  var microhangsInNavWindow: Int
  var fullHangsInNavWindow: Int
}

/// Drives `xctrace export` against every `.trace` bundle in the given
/// directory, parses the per-iteration metrics, and returns the median
/// across iterations. Fails closed on missing schemas or empty output —
/// `make perf` must never declare a silent green.
enum TraceMetricsAggregator {
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
      microhangsInWindow.append(m.microhangsInNavWindow)
      fullHangsInWindow.append(m.fullHangsInNavWindow)
    }

    return TraceMetrics(
      contentviewBodyGetterPct: bodyPcts.median() ?? 0,
      contentviewUnreadEntriesGetterPct: unreadPcts.median() ?? 0,
      sidebarNavGetterPct: sidebarNavPcts.median() ?? 0,
      microhangsGe250MsCount: medianInt(microhangs),
      fullHangsGe500MsCount: medianInt(fullHangs),
      microhangsInNavWindow: medianInt(microhangsInWindow),
      fullHangsInNavWindow: medianInt(fullHangsInWindow)
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
    guard hasSignpost else {
      throw PerfParserError(
        message: "trace \(traceURL.lastPathComponent) is missing os-signpost / points-of-interest "
          + "schema; the stock 'Time Profiler' template does not record signposts headlessly — "
          + "re-record with Tools/PerfParser/FeederPerf.tracetemplate (Time Profiler + Hangs + "
          + "os_signpost). Without it the perf-nav-window interval cannot be resolved."
      )
    }

    let schemaName = tocXML.contains("schema=\"time-sample\"") ? "time-sample" : "time-profile"
    let hangSchema =
      tocXML.contains("schema=\"hang-events\"")
      ? "hang-events" : "potential-hangs"
    let signpostSchema =
      tocXML.contains("schema=\"os-signpost\"")
      ? "os-signpost" : "points-of-interest"

    let timeXML = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xctrace", "export", "--input", traceURL.path,
        "--xpath", "/trace-toc/run/data/table[@schema=\"\(schemaName)\"]",
      ]
    )
    let shares = try parseTimeProfile(xml: timeXML)

    let signpostXML = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xctrace", "export", "--input", traceURL.path,
        "--xpath", "/trace-toc/run/data/table[@schema=\"\(signpostSchema)\"]",
      ]
    )
    guard let window = parseSignpostWindow(xml: signpostXML, name: "perf-nav-window") else {
      throw PerfParserError(
        message: "trace \(traceURL.lastPathComponent) has an os-signpost table but no resolvable "
          + "`perf-nav-window` interval; the scenario may have exited before endInterval fired. "
          + "Re-record and confirm PerfScenarioRunner reached the end of the nav walk."
      )
    }

    let hangsXML = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xctrace", "export", "--input", traceURL.path,
        "--xpath", "/trace-toc/run/data/table[@schema=\"\(hangSchema)\"]",
      ]
    )
    let hangEvents = try parseHangEvents(xml: hangsXML)
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
    let handler = SignpostRowHandler()
    let parser = XMLParser(data: xml)
    parser.delegate = handler
    guard parser.parse() else { return nil }
    return resolveInterval(rows: handler.rows, name: name)
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
  static func countHangs(
    _ events: [HangEvent], window: (start: Double, end: Double)?
  ) -> (micro: Int, full: Int, microInWindow: Int, fullInWindow: Int) {
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

/// SAX-style handler for `xctrace`'s time-profile export. The export inlines
/// symbol names as `<frame name="…"/>` children under each sample row; we sum
/// the `<weight>` value when the sample's frames name one of the hot symbols.
/// Unrelated rows still contribute to the total so the resulting percentage is
/// the inclusive share of main-thread time the symbol consumed.
final class TimeProfileSampleHandler: NSObject, XMLParserDelegate {
  var totalWeight: Double = 0
  var bodyWeight: Double = 0
  var unreadWeight: Double = 0
  var sidebarNavWeight: Double = 0
  private var currentSampleSymbols: [String] = []
  private var characterBuffer: String = ""
  private var currentElement: String = ""
  private var currentWeight: Double = 0

  func parser(
    _ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    currentElement = elementName
    characterBuffer = ""
    // Frame symbol names come either as the `name` attribute on `<frame>`
    // or inline as the text content of `<frame>`/`<backtrace>` children.
    if let name = attributeDict["name"], !name.isEmpty {
      currentSampleSymbols.append(name)
    }
    if elementName == "row" || elementName == "sample" {
      currentSampleSymbols = []
      currentWeight = 0
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
      }
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
/// The signpost NAME (the `StaticString` passed to `beginInterval`) appears
/// either as a `name`/`os-signpost-name` attribute or as element text; the
/// start-time and duration appear as `start-time`/`sample-time`/`event-time`
/// and `duration` (element text or attribute).
final class SignpostRowHandler: NSObject, XMLParserDelegate {
  var rows: [SignpostRow] = []
  private var currentElement: String = ""
  private var characterBuffer: String = ""
  private var name: String = ""
  private var time: Double?
  private var duration: Double?
  private var phase: String?
  private var inRow = false

  private static let timeElements: Set<String> = [
    "start-time", "sample-time", "event-time", "time",
  ]

  func parser(
    _ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    currentElement = elementName
    characterBuffer = ""
    if elementName == "row" {
      inRow = true
      name = ""
      time = nil
      duration = nil
      phase = nil
    }
    guard inRow else { return }
    if let attrName = attributeDict["name"] ?? attributeDict["os-signpost-name"], !attrName.isEmpty {
      name = attrName
    }
    if let phaseAttr = attributeDict["event-type"] ?? attributeDict["phase"], !phaseAttr.isEmpty {
      phase = phaseAttr
    }
    if let durationAttr = attributeDict["duration"], let value = Double(durationAttr) {
      duration = value
    }
    for key in Self.timeElements {
      if let value = attributeDict[key], let parsed = Double(value) {
        time = parsed
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
      if Self.timeElements.contains(elementName), let value = Double(trimmed) {
        time = value
      } else if elementName == "duration", let value = Double(trimmed) {
        duration = value
      } else if elementName == "os-signpost-name" || elementName == "name" {
        name = trimmed
      } else if elementName == "event-type" || elementName == "phase" {
        phase = trimmed
      } else if name.isEmpty, trimmed.contains("perf-nav-window") {
        // Some exports carry the interval name as the row's message text.
        name = trimmed
      }
    }
    if elementName == "row", inRow {
      rows.append(SignpostRow(name: name, time: time, duration: duration, phase: phase))
      inRow = false
    }
    characterBuffer = ""
  }
}

/// SAX-style handler for the `potential-hangs` / `hang-events` export. Reads
/// both the `duration` field (nanoseconds in the modern schema; falls back to
/// seconds when the value looks too small) and the hang's start-time so the
/// aggregator can window the count to the nav interval.
final class HangsHandler: NSObject, XMLParserDelegate {
  var events: [TraceMetricsAggregator.HangEvent] = []
  private var currentElement: String = ""
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
    currentElement = elementName
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
  print("  microhangs_in_nav_window: \(metrics.microhangsInNavWindow)")
  print("  full_hangs_in_nav_window: \(metrics.fullHangsInNavWindow)")
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
  compareOptional(
    name: "microhangs_in_nav_window",
    captured: Double(metrics.microhangsInNavWindow),
    metric: baseline.level4Trace.microhangsInNavWindow,
    capturedFmt: "%.0f", compareFmt: "%.0f vs threshold %.0f"
  )
  compareOptional(
    name: "full_hangs_in_nav_window",
    captured: Double(metrics.fullHangsInNavWindow),
    metric: baseline.level4Trace.fullHangsInNavWindow,
    capturedFmt: "%.0f", compareFmt: "%.0f vs threshold %.0f"
  )
  return allPass
}
