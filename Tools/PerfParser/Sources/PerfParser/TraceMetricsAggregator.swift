import Foundation

// MARK: - Level 4 trace metrics

struct TraceMetrics {
  var contentviewBodyGetterPct: Double
  var contentviewUnreadEntriesGetterPct: Double
  var microhangsGe250MsCount: Int
  var fullHangsGe500MsCount: Int
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
    var microhangs: [Int] = []
    var fullHangs: [Int] = []

    for trace in traces {
      let iterationMetrics = try extractMetrics(traceURL: trace)
      bodyPcts.append(iterationMetrics.contentviewBodyGetterPct)
      unreadPcts.append(iterationMetrics.contentviewUnreadEntriesGetterPct)
      microhangs.append(iterationMetrics.microhangsGe250MsCount)
      fullHangs.append(iterationMetrics.fullHangsGe500MsCount)
    }

    return TraceMetrics(
      contentviewBodyGetterPct: bodyPcts.median() ?? 0,
      contentviewUnreadEntriesGetterPct: unreadPcts.median() ?? 0,
      microhangsGe250MsCount: medianInt(microhangs),
      fullHangsGe500MsCount: medianInt(fullHangs)
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

    let schemaName = tocXML.contains("schema=\"time-sample\"") ? "time-sample" : "time-profile"
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
    let (bodyPct, unreadPct) = try parseTimeProfile(xml: timeXML)

    let hangsXML = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xctrace", "export", "--input", traceURL.path,
        "--xpath", "/trace-toc/run/data/table[@schema=\"\(hangSchema)\"]",
      ]
    )
    let (micro, full) = try parseHangs(xml: hangsXML)

    return TraceMetrics(
      contentviewBodyGetterPct: bodyPct,
      contentviewUnreadEntriesGetterPct: unreadPct,
      microhangsGe250MsCount: micro,
      fullHangsGe500MsCount: full
    )
  }

  // MARK: - XML parsing

  /// Parse a time-profile / time-sample export. Sums per-frame sample weights
  /// that name `ContentView.body.getter` (resp. `ContentView.unreadEntries`)
  /// and divides by the total sample weight to produce an inclusive sample
  /// percentage.
  static func parseTimeProfile(xml: Data) throws -> (bodyPct: Double, unreadPct: Double) {
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
    let bodyPct = handler.bodyWeight / total * 100.0
    let unreadPct = handler.unreadWeight / total * 100.0
    return (bodyPct, unreadPct)
  }

  /// Count `potential-hang` / `hang-event` rows whose duration field is at or
  /// above 250 ms (microhang) and 500 ms (full hang).
  static func parseHangs(xml: Data) throws -> (microhangs: Int, fullHangs: Int) {
    let handler = HangsHandler()
    let parser = XMLParser(data: xml)
    parser.delegate = handler
    if !parser.parse() {
      throw PerfParserError(
        message:
          "failed to parse hangs XML: \(parser.parserError?.localizedDescription ?? "<no error>")"
      )
    }
    return (handler.microhangCount, handler.fullHangCount)
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
/// the `<weight>` value when the most recent frame name matches one of the
/// hot symbols. Unrelated rows still contribute to the total so the resulting
/// percentage is the inclusive share of main-thread time the symbol consumed.
final class TimeProfileSampleHandler: NSObject, XMLParserDelegate {
  var totalWeight: Double = 0
  var bodyWeight: Double = 0
  var unreadWeight: Double = 0
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
      currentSampleSymbols = []
      currentWeight = 0
    default:
      break
    }
    characterBuffer = ""
  }
}

/// SAX-style handler for the `potential-hangs` / `hang-events` export. Reads
/// the `duration` field (nanoseconds in the modern schema; falls back to ms
/// when expressed in the older schema) and counts rows hitting the two
/// thresholds.
final class HangsHandler: NSObject, XMLParserDelegate {
  var microhangCount: Int = 0
  var fullHangCount: Int = 0
  private var currentDurationText: String = ""
  private var currentElement: String = ""

  func parser(
    _ parser: XMLParser, didStartElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    currentElement = elementName
    if elementName == "row" || elementName == "hang" {
      currentDurationText = ""
    }
    if let durationStr = attributeDict["duration"], !durationStr.isEmpty {
      currentDurationText = durationStr
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if currentElement == "duration" {
      currentDurationText.append(string)
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String,
    namespaceURI: String?, qualifiedName qName: String?
  ) {
    if elementName == "row" || elementName == "hang" {
      let trimmed = currentDurationText.trimmingCharacters(in: .whitespacesAndNewlines)
      if let durationNs = Double(trimmed) {
        // xctrace defaults to nanoseconds; if the value looks too small,
        // assume seconds and scale up.
        let durationMs = durationNs >= 1_000_000 ? durationNs / 1_000_000 : durationNs * 1000
        if durationMs >= 500 { fullHangCount += 1 }
        if durationMs >= 250 { microhangCount += 1 }
      }
      currentDurationText = ""
    }
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
  print("  microhangs_ge_250ms_count: \(metrics.microhangsGe250MsCount)")
  print("  full_hangs_ge_500ms_count: \(metrics.fullHangsGe500MsCount)")
}

func compareTraceMetrics(_ metrics: TraceMetrics, baseline: BaselineDocument) -> Bool {
  var allPass = true

  func compare(name: String, captured: Double, threshold: Double, fmt: String) {
    let line = String(format: fmt, captured, threshold)
    if captured > threshold {
      print("FAIL  \(name): \(line)")
      allPass = false
    } else {
      print("PASS  \(name): \(line)")
    }
  }

  compare(
    name: "contentview_body_getter_pct",
    captured: metrics.contentviewBodyGetterPct,
    threshold: baseline.level4Trace.contentviewBodyGetterPct.max,
    fmt: "%.2f%% vs threshold %.2f%%"
  )
  compare(
    name: "contentview_unread_entries_getter_pct",
    captured: metrics.contentviewUnreadEntriesGetterPct,
    threshold: baseline.level4Trace.contentviewUnreadEntriesGetterPct.max,
    fmt: "%.2f%% vs threshold %.2f%%"
  )
  compare(
    name: "microhangs_ge_250ms_count",
    captured: Double(metrics.microhangsGe250MsCount),
    threshold: baseline.level4Trace.microhangsGe250MsCount.max,
    fmt: "%.0f vs threshold %.0f"
  )
  compare(
    name: "full_hangs_ge_500ms_count",
    captured: Double(metrics.fullHangsGe500MsCount),
    threshold: baseline.level4Trace.fullHangsGe500MsCount.max,
    fmt: "%.0f vs threshold %.0f"
  )
  return allPass
}
