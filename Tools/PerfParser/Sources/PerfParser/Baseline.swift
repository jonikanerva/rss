import Foundation

// MARK: - Baseline JSON schema

/// The on-disk shape of `Tests/PerfBaselines/baseline-*.json`. Captured-host
/// metadata + Level 1 micro-benchmarks + Level 2 medians + Level 4 absolute
/// thresholds. Each `level*` section is populated independently — Level 1
/// and Level 2 captured values can be `nil` (no baseline yet) while Level 4
/// thresholds are populated from the pre-perf-fix diagnosis run.
struct BaselineDocument: Codable {
  var schemaVersion: Int
  var capturedOn: String?
  var capturedHostCPU: String?
  var level1Microbench: Level1Microbench?
  var level2Signposts: Level2Signposts
  var level4Trace: Level4Trace
  var previousMainHEADRecord: PreviousMainHEADRecord?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case capturedOn = "captured_on"
    case capturedHostCPU = "captured_host_cpu"
    case level1Microbench = "level1_microbench"
    case level2Signposts = "level2_signposts"
    case level4Trace = "level4_trace"
    case previousMainHEADRecord = "previous_main_head_record"
  }
}

/// Level 1 of the perf suite: per-function XCTest `measure { }` medians.
/// Entries are keyed by the XCTest method name with the `test_` prefix
/// stripped (e.g. `fetchUnreadCountsSnapshot_micro`). The shared
/// `tolerancePct` applies to every entry — the comparator allows
/// `captured <= baseline * (1 + tolerance/100)`.
struct Level1Microbench: Codable {
  var tolerancePct: Double
  var capturedOn: String?
  var notes: String?
  var entries: [String: Level1Entry]

  enum CodingKeys: String, CodingKey {
    case tolerancePct = "tolerance_pct"
    case capturedOn = "captured_on"
    case notes
    case entries
  }
}

struct Level1Entry: Codable {
  var medianMs: Double?

  enum CodingKeys: String, CodingKey {
    case medianMs = "median_ms"
  }
}

struct Level2Signposts: Codable {
  var sidebarClickMedianMs: Double?
  var articleClickMedianMs: Double?
  var detailRenderMedianMs: Double?
  var tolerancePct: Double
  var frameBudgetMs: Double

  enum CodingKeys: String, CodingKey {
    case sidebarClickMedianMs = "sidebar_click_median_ms"
    case articleClickMedianMs = "article_click_median_ms"
    case detailRenderMedianMs = "detail_render_median_ms"
    case tolerancePct = "tolerance_pct"
    case frameBudgetMs = "frame_budget_ms"
  }
}

struct Level4Trace: Codable {
  var contentviewBodyGetterPct: ThresholdMetric
  var contentviewUnreadEntriesGetterPct: ThresholdMetric
  var microhangsGe250MsCount: ThresholdMetric
  var fullHangsGe500MsCount: ThresholdMetric
  /// Metrics added by the nav-stutter measurement harness. Optional so a
  /// baseline written before this shape (or one that omits them) still
  /// decodes — a missing metric reads as "report-only, no gate".
  var sidebarNavGetterPct: ThresholdMetric?
  var microhangsInNavWindow: ThresholdMetric?
  var fullHangsInNavWindow: ThresholdMetric?

  enum CodingKeys: String, CodingKey {
    case contentviewBodyGetterPct = "contentview_body_getter_pct"
    case contentviewUnreadEntriesGetterPct = "contentview_unread_entries_getter_pct"
    case microhangsGe250MsCount = "microhangs_ge_250ms_count"
    case fullHangsGe500MsCount = "full_hangs_ge_500ms_count"
    case sidebarNavGetterPct = "sidebar_nav_getter_pct"
    case microhangsInNavWindow = "microhangs_in_nav_window"
    case fullHangsInNavWindow = "full_hangs_in_nav_window"
  }
}

/// A metric's ceiling + captured value. `max` is nullable: a null ceiling
/// means the metric is report-only (the comparator SKIPs it) — used while a
/// symptom is being measured but not yet blessed into a gate (Guard #1).
struct ThresholdMetric: Codable {
  var max: Double?
  var captured: Double?
}

struct PreviousMainHEADRecord: Codable {
  var contentviewBodyGetterPct: Double
  var contentviewUnreadEntriesGetterPct: Double
  var microhangsGe250MsCount: Double
  var fullHangsGe500MsCount: Double
  var sessionSeconds: Double
  var capturedFor: String

  enum CodingKeys: String, CodingKey {
    case contentviewBodyGetterPct = "contentview_body_getter_pct"
    case contentviewUnreadEntriesGetterPct = "contentview_unread_entries_getter_pct"
    case microhangsGe250MsCount = "microhangs_ge_250ms_count"
    case fullHangsGe500MsCount = "full_hangs_ge_500ms_count"
    case sessionSeconds = "session_seconds"
    case capturedFor = "captured_for"
  }
}

// MARK: - Load / write

func loadBaseline(at path: String) throws -> BaselineDocument {
  let url = URL(fileURLWithPath: path)
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw PerfParserError(message: "baseline JSON not found at \(path)")
  }
  let data = try Data(contentsOf: url)
  do {
    return try JSONDecoder().decode(BaselineDocument.self, from: data)
  } catch {
    throw PerfParserError(
      message: "failed to decode baseline JSON at \(path): \(error.localizedDescription)"
    )
  }
}

enum Baseline {
  /// Merges captured Level 1 micro-benchmark medians into the existing
  /// baseline document. Unknown benchmark names (present in measurements
  /// but not in the baseline's `entries` map) are added so a newly-named
  /// benchmark gets a slot on first capture; existing entries have their
  /// `medianMs` overwritten. Tolerance and notes are preserved.
  static func writeMicroBenchmarkMedians(
    _ medians: MicroBenchmarkMedians,
    into path: String,
    current: BaselineDocument
  ) throws {
    var doc = current
    var section =
      doc.level1Microbench
      ?? Level1Microbench(tolerancePct: 20, capturedOn: nil, notes: nil, entries: [:])
    for (name, medianMs) in medians.medianMsByName {
      var entry = section.entries[name] ?? Level1Entry(medianMs: nil)
      entry.medianMs = medianMs
      section.entries[name] = entry
    }
    section.capturedOn = ISO8601DateFormatter().string(from: Date())
    doc.level1Microbench = section
    if doc.capturedOn == nil {
      doc.capturedOn = ISO8601DateFormatter().string(from: Date())
    }
    if doc.capturedHostCPU == nil {
      doc.capturedHostCPU = currentHostCPU() ?? "unknown"
    }
    try writeBaseline(doc, to: path)
  }

  static func writeSignpostMedians(
    _ medians: SignpostMedians,
    into path: String,
    current: BaselineDocument
  ) throws {
    var doc = current
    doc.level2Signposts.sidebarClickMedianMs = medians.sidebarClickMs
    doc.level2Signposts.articleClickMedianMs = medians.articleClickMs
    doc.level2Signposts.detailRenderMedianMs = medians.detailRenderMs
    if doc.capturedOn == nil {
      doc.capturedOn = ISO8601DateFormatter().string(from: Date())
    }
    if doc.capturedHostCPU == nil {
      doc.capturedHostCPU = currentHostCPU() ?? "unknown"
    }
    try writeBaseline(doc, to: path)
  }

  static func writeTraceMetrics(
    _ metrics: TraceMetrics,
    into path: String,
    current: BaselineDocument
  ) throws {
    var doc = current
    doc.level4Trace.contentviewBodyGetterPct.captured = metrics.contentviewBodyGetterPct
    doc.level4Trace.contentviewUnreadEntriesGetterPct.captured =
      metrics
      .contentviewUnreadEntriesGetterPct
    doc.level4Trace.microhangsGe250MsCount.captured = Double(metrics.microhangsGe250MsCount)
    doc.level4Trace.fullHangsGe500MsCount.captured = Double(metrics.fullHangsGe500MsCount)
    // New nav-stutter metrics: record captured values while keeping any
    // existing `max` (null = report-only) untouched. Preserve the metric slot
    // if the baseline already declared one; otherwise create a report-only
    // slot (null max) so a first write does not accidentally bless a ceiling.
    setCaptured(
      &doc.level4Trace.sidebarNavGetterPct, to: metrics.sidebarNavGetterPct)
    // Windowed counts may be nil (no signpost table); only record a captured
    // value when it was actually measured.
    if let micro = metrics.microhangsInNavWindow {
      setCaptured(&doc.level4Trace.microhangsInNavWindow, to: Double(micro))
    }
    if let full = metrics.fullHangsInNavWindow {
      setCaptured(&doc.level4Trace.fullHangsInNavWindow, to: Double(full))
    }
    if doc.capturedOn == nil {
      doc.capturedOn = ISO8601DateFormatter().string(from: Date())
    }
    if doc.capturedHostCPU == nil {
      doc.capturedHostCPU = currentHostCPU() ?? "unknown"
    }
    try writeBaseline(doc, to: path)
  }

  /// Record a captured value into an optional metric slot without touching
  /// its `max`. Creates a report-only slot (null max) when none exists, so a
  /// first write never invents a ceiling.
  private static func setCaptured(_ metric: inout ThresholdMetric?, to value: Double) {
    if metric == nil {
      metric = ThresholdMetric(max: nil, captured: value)
    } else {
      metric?.captured = value
    }
  }

  private static func writeBaseline(_ doc: BaselineDocument, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(doc)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

// MARK: - Host CPU detection

/// Read `machdep.cpu.brand_string` via `sysctl -n`. Used to host-key the
/// baseline so a baseline captured on machine A cannot silently apply to
/// machine B.
func currentHostCPU() -> String? {
  let data = (try? runProcess(launchPath: "/usr/sbin/sysctl", arguments: ["-n", "machdep.cpu.brand_string"])) ?? Data()
  let text = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return (text?.isEmpty == false) ? text : nil
}
