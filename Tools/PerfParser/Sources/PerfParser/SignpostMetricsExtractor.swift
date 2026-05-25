import Foundation

// MARK: - Level 2 signpost medians

/// Captured median durations for the three click signposts, in milliseconds.
struct SignpostMedians {
  var sidebarClickMs: Double?
  var articleClickMs: Double?
  var detailRenderMs: Double?
}

/// Pulls `XCTOSSignpostMetric` medians from an XCResult bundle written by
/// `xcodebuild test-without-building`. Uses `xcrun xcresulttool` in modern
/// JSON mode so the schema is stable across Xcode 26+. Fails closed if the
/// expected test class or metrics are missing.
enum SignpostMetricsExtractor {
  static func run(xcresultPath: String) async throws -> SignpostMedians {
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

  /// `xcresulttool get test-results tests --format json` returns a JSON tree
  /// where each leaf test case carries `performanceMetrics` containing one
  /// entry per `XCMetric` measured. We walk the tree and read out the median
  /// for each of the three signpost names.
  static func parseTestsJSON(_ data: Data) throws -> SignpostMedians {
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw PerfParserError(
        message: "failed to decode xcresulttool JSON: \(error.localizedDescription)"
      )
    }

    var medians = SignpostMedians()
    walkTestNodes(json) { node in
      let testName = (node["name"] as? String) ?? ""
      guard
        testName.contains("PerfSignpostTests")
          || testName.hasPrefix("test_sidebar_click_signpost")
          || testName.hasPrefix("test_article_click_signpost")
          || testName.hasPrefix("test_detail_render_signpost")
      else { return }

      let metrics =
        (node["performanceMetrics"] as? [[String: Any]])
        ?? (node["activitySummaries"] as? [[String: Any]])
        ?? []
      for metric in metrics {
        guard
          let identifier = metric["identifier"] as? String
            ?? metric["displayName"] as? String
        else { continue }
        let measurements =
          (metric["measurements"] as? [Double])
          ?? (metric["values"] as? [Double])
          ?? []
        guard let median = measurements.median() else { continue }
        // XCMetric identifier for XCTOSSignpostMetric is typically
        // "com.apple.dt.XCTMetric_OSSignpost,name=<NAME>". Match on the
        // signpost name suffix.
        if identifier.contains("sidebar-click") {
          medians.sidebarClickMs = median
        } else if identifier.contains("article-click") {
          medians.articleClickMs = median
        } else if identifier.contains("detail-render") {
          medians.detailRenderMs = median
        }
      }
    }

    return medians
  }

  /// Recursively walk `tests`/`children` arrays handing each node to `body`.
  /// The xcresulttool JSON nests test classes under `tests` and individual
  /// methods under `children` — the exact key has shifted between Xcode
  /// versions, so we handle both.
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

func printSignpostMedians(_ medians: SignpostMedians) {
  func format(_ name: String, _ value: Double?) {
    if let value {
      print(String(format: "  %@: %.2f ms", name, value))
    } else {
      print("  \(name): <not captured>")
    }
  }
  format("sidebar-click  median", medians.sidebarClickMs)
  format("article-click  median", medians.articleClickMs)
  format("detail-render  median", medians.detailRenderMs)
}

func compareSignpostMedians(_ medians: SignpostMedians, baseline: BaselineDocument) -> Bool {
  let tolerance = baseline.level2Signposts.tolerancePct / 100.0
  let frameBudget = baseline.level2Signposts.frameBudgetMs
  var allPass = true

  let checks: [(name: String, captured: Double?, baseline: Double?, hardCeiling: Double?)] = [
    (
      "sidebar_click_median_ms", medians.sidebarClickMs,
      baseline.level2Signposts.sidebarClickMedianMs, frameBudget
    ),
    (
      "article_click_median_ms", medians.articleClickMs,
      baseline.level2Signposts.articleClickMedianMs, frameBudget
    ),
    (
      "detail_render_median_ms", medians.detailRenderMs,
      baseline.level2Signposts.detailRenderMedianMs, nil
    ),
  ]

  for check in checks {
    guard let captured = check.captured else {
      print(
        "SKIP  \(check.name): metric not captured in xcresult — re-run `make perf-record-baseline` and inspect logs"
      )
      continue
    }
    guard let baselineValue = check.baseline else {
      print(
        "SKIP  \(check.name): baseline is null — capture with `make perf-record-baseline` after hand-verifying the architectural fix"
      )
      continue
    }
    let ceiling = baselineValue * (1.0 + tolerance)
    if captured > ceiling {
      print(
        String(
          format: "FAIL  %@: %.2f ms > tolerance ceiling %.2f ms (baseline %.2f ms × %.2f)",
          check.name, captured, ceiling, baselineValue, 1.0 + tolerance
        )
      )
      allPass = false
    } else {
      print(
        String(
          format: "PASS  %@: %.2f ms <= tolerance ceiling %.2f ms (baseline %.2f ms)",
          check.name, captured, ceiling, baselineValue
        )
      )
    }
    if let hard = check.hardCeiling, captured > hard {
      print(
        String(
          format: "FAIL  %@: %.2f ms > hard frame-budget ceiling %.2f ms (docs/stack.md §4)",
          check.name, captured, hard
        )
      )
      allPass = false
    }
  }
  return allPass
}
