import Foundation

// MARK: - Level 1 micro-benchmark medians

/// Captured median wall-clock durations (in milliseconds) for the
/// `XCTest measure { }` blocks under `FeederTests/MicroBenchmarkTests`.
/// Keyed by the XCTest method name with the leading `test_` stripped and
/// trailing `()` removed — matching the entry keys in
/// `Tests/PerfBaselines/baseline-current.json` under `level1_microbench.entries`.
struct MicroBenchmarkMedians {
  var medianMsByName: [String: Double]
}

/// Extracts XCTest `measure { }` medians from the same XCResult bundle
/// `make perf-signpost` already produces. Walks the JSON returned by
/// `xcrun xcresulttool get test-results tests --format json` and filters
/// for the four micro-benchmark test methods. The metric is the default
/// `XCTPerformanceMetric_WallClockTime` (Xcode 26 modernised display name
/// is "Clock Monotonic Time" / identifier `com.apple.dt.XCTMetric_Clock.time.monotonic`).
/// Per-iteration values are seconds — converted to milliseconds for parity
/// with the Level 2 signpost medians.
enum MicroBenchmarkMetricsExtractor {
  /// Names of the four hot-path benchmarks shipped in PR 4. New benchmarks
  /// added under `FeederTests/MicroBenchmarkTests` are picked up
  /// automatically by the suffix match — this list is only the documented
  /// minimum the perf gate enforces, not an exhaustive enumeration.
  static let knownBenchmarkNames: [String] = [
    "fetchUnreadCountsSnapshot_micro",
    "fetchEntrySections_category_micro",
    "parseHTMLToBlocks_micro",
    "groupEntriesByDay_micro",
  ]

  static func run(xcresultPath: String) async throws -> MicroBenchmarkMedians {
    let url = URL(fileURLWithPath: xcresultPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PerfParserError(message: "xcresult bundle not found at \(xcresultPath)")
    }
    let stdout = try runProcess(
      launchPath: "/usr/bin/xcrun",
      arguments: [
        "xcresulttool", "get", "test-results", "tests",
        "--path", url.path,
        "--format", "json",
        "--compact",
      ]
    )
    return try parseTestsJSON(stdout)
  }

  // MARK: - JSON parsing

  /// Walks the xcresulttool tests tree and collects medians for each test
  /// node whose name starts with one of the `MicroBenchmarkTests.test_…`
  /// methods. Per-test wall-clock measurements come from
  /// `performanceMetrics[i].measurements: [Double]` in seconds.
  static func parseTestsJSON(_ data: Data) throws -> MicroBenchmarkMedians {
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw PerfParserError(
        message: "failed to decode xcresulttool JSON: \(error.localizedDescription)"
      )
    }

    var medianMsByName: [String: Double] = [:]
    walkTestNodes(json) { node in
      guard let benchKey = microBenchmarkKey(forNode: node) else { return }
      let metrics =
        (node["performanceMetrics"] as? [[String: Any]])
        ?? (node["activitySummaries"] as? [[String: Any]])
        ?? []
      for metric in metrics {
        let identifier =
          (metric["identifier"] as? String)
          ?? (metric["displayName"] as? String)
          ?? ""
        guard isWallClockMetric(identifier: identifier) else { continue }
        let measurements =
          (metric["measurements"] as? [Double])
          ?? (metric["values"] as? [Double])
          ?? []
        guard let median = measurements.median() else { continue }
        // XCTest's WallClockTime metric reports seconds; convert to ms.
        medianMsByName[benchKey] = median * 1000.0
      }
    }

    return MicroBenchmarkMedians(medianMsByName: medianMsByName)
  }

  /// Returns the canonical entry key (`fetchUnreadCountsSnapshot_micro`,
  /// etc.) for a test JSON node, or `nil` if the node is not one of the
  /// micro-benchmark methods. Strips a leading `test_` and a trailing
  /// `()` so a node named `test_fetchUnreadCountsSnapshot_micro()` maps to
  /// the baseline entry key `fetchUnreadCountsSnapshot_micro`.
  static func microBenchmarkKey(forNode node: [String: Any]) -> String? {
    let name = (node["name"] as? String) ?? ""
    guard !name.isEmpty else { return nil }
    // Require the node lives under MicroBenchmarkTests; xcresulttool
    // surfaces the parent class in the leaf `identifier` (e.g.
    // "MicroBenchmarkTests/test_parseHTMLToBlocks_micro()"). Fall back to
    // matching `_micro` suffix on the name when the identifier is absent.
    let identifier = (node["identifier"] as? String) ?? ""
    let isUnderSuite =
      identifier.contains("MicroBenchmarkTests")
      || name.contains("MicroBenchmarkTests")
    let trimmedName =
      name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "()", with: "")
    let methodName =
      trimmedName.hasPrefix("test_")
      ? String(trimmedName.dropFirst("test_".count))
      : trimmedName
    guard methodName.hasSuffix("_micro") else { return nil }
    guard isUnderSuite || knownBenchmarkNames.contains(methodName) else { return nil }
    return methodName
  }

  /// XCTest's default `measure { }` metric is wall-clock time. The legacy
  /// identifier is `com.apple.XCTPerformanceMetric_WallClockTime`; Xcode 26
  /// presents the modernised identifier `com.apple.dt.XCTMetric_Clock.time.monotonic`
  /// with display name "Clock Monotonic Time". Match both plus the bare
  /// "Time" display name swift-corelibs-xctest emits.
  static func isWallClockMetric(identifier: String) -> Bool {
    let lower = identifier.lowercased()
    return lower.contains("wallclock")
      || lower.contains("clock.time.monotonic")
      || lower.contains("clock monotonic")
      || lower == "time"
      || lower == "time, seconds"
  }

  /// Recursively walk `tests`/`children` arrays handing each node to `body`.
  /// Mirrors the helper used by `SignpostMetricsExtractor` to handle the
  /// xcresulttool JSON variations between Xcode releases.
  private static func walkTestNodes(_ any: Any, body: ([String: Any]) -> Void) {
    if let dict = any as? [String: Any] {
      body(dict)
      for value in dict.values {
        walkTestNodes(value, body: body)
      }
    } else if let array = any as? [Any] {
      for element in array {
        walkTestNodes(element, body: body)
      }
    }
  }
}

// MARK: - Reporting

func printMicroBenchmarkMedians(_ medians: MicroBenchmarkMedians) {
  if medians.medianMsByName.isEmpty {
    print("  <no MicroBenchmarkTests measurements found in xcresult>")
    return
  }
  for name in medians.medianMsByName.keys.sorted() {
    let value = medians.medianMsByName[name] ?? 0
    print(String(format: "  %@ median: %.3f ms", name, value))
  }
}

/// Compares captured medians against the baseline section using the shared
/// `tolerance_pct`. A missing baseline entry (or missing capture) emits
/// SKIP rather than FAIL so the first `make perf-record-baseline` pass
/// does not block subsequent perf runs. Mirrors the L2 comparator contract:
/// SKIP on missing data, FAIL on exceeded tolerance, PASS otherwise.
func compareMicroBenchmarkMedians(
  _ medians: MicroBenchmarkMedians, baseline: BaselineDocument
) -> Bool {
  guard let section = baseline.level1Microbench else {
    print(
      "SKIP  level1_microbench: section missing from baseline JSON — "
        + "first capture happens on `make perf-record-baseline`"
    )
    return true
  }
  let tolerance = section.tolerancePct / 100.0
  var allPass = true

  // Iterate the union of baseline keys + captured keys so newly-added
  // benchmarks show up as SKIP (no baseline) and disappeared benchmarks
  // show up as SKIP (no capture) rather than vanishing silently.
  let allNames = Set(section.entries.keys).union(medians.medianMsByName.keys).sorted()
  for name in allNames {
    let captured = medians.medianMsByName[name]
    let baselineValue = section.entries[name]?.medianMs

    guard let captured else {
      print(
        "SKIP  level1_microbench[\(name)]: not captured in xcresult — "
          + "re-run `make perf-signpost` and inspect logs"
      )
      continue
    }
    guard let baselineValue else {
      print(
        "SKIP  level1_microbench[\(name)]: baseline median_ms is null — "
          + "capture with `make perf-record-baseline`"
      )
      continue
    }
    let ceiling = baselineValue * (1.0 + tolerance)
    if captured > ceiling {
      print(
        String(
          format: "FAIL  level1_microbench[%@]: %.3f ms > tolerance ceiling %.3f ms "
            + "(baseline %.3f ms × %.2f)",
          name, captured, ceiling, baselineValue, 1.0 + tolerance
        )
      )
      allPass = false
    } else {
      print(
        String(
          format: "PASS  level1_microbench[%@]: %.3f ms <= ceiling %.3f ms (baseline %.3f ms)",
          name, captured, ceiling, baselineValue
        )
      )
    }
  }
  return allPass
}
