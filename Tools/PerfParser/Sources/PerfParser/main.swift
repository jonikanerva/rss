import Foundation

// MARK: - PerfParser entry point

/// CLI for the headless perf suite. Two modes:
///
/// - Level 2 (`--xcresult <path> --baseline <path>`): extract
///   `XCTOSSignpostMetric` medians from a single XCResult bundle produced by
///   `xcodebuild test-without-building -only-testing:FeederTests/PerfSignpostTests`
///   and compare against the baseline JSON.
/// - Level 4 (`--trace-dir <dir> --baseline <path> [--write-baseline]`):
///   shell out to `xcrun xctrace export` for each `.trace` under the given
///   directory, take per-metric medians across iterations, then either
///   compare against the baseline JSON or overwrite the baseline.
///
/// Exit codes:
/// - `0` — comparison passed (or `--write-baseline` succeeded).
/// - `2` — comparison failed.
/// - `1` — internal error: missing input, missing schema, parse failure.
///
/// All failures bail with a clear stderr message naming what was missing —
/// no silent green per the perf-suite design.

@MainActor
func runMain() async -> Int32 {
  let args = CommandLine.arguments.dropFirst()
  var xcresultPath: String?
  var traceDir: String?
  var baselinePath: String?
  var writeBaseline = false

  var iterator = args.makeIterator()
  while let arg = iterator.next() {
    switch arg {
    case "--xcresult":
      xcresultPath = iterator.next()
    case "--trace-dir":
      traceDir = iterator.next()
    case "--baseline":
      baselinePath = iterator.next()
    case "--write-baseline":
      writeBaseline = true
    case "--help", "-h":
      printUsage()
      return 0
    default:
      stderr("PerfParser: unknown argument: \(arg)")
      printUsage()
      return 1
    }
  }

  guard let baselinePath else {
    stderr("PerfParser: --baseline is required")
    return 1
  }

  do {
    let baseline = try loadBaseline(at: baselinePath)
    var anyFail = false
    var anyMode = false

    if let xcresultPath {
      anyMode = true
      let medians = try await SignpostMetricsExtractor.run(xcresultPath: xcresultPath)
      print("== Level 2 signpost medians ==")
      printSignpostMedians(medians)
      if writeBaseline {
        try Baseline.writeSignpostMedians(medians, into: baselinePath, current: baseline)
        print("PerfParser: wrote Level 2 baseline to \(baselinePath)")
      } else {
        let pass = compareSignpostMedians(medians, baseline: baseline)
        if !pass { anyFail = true }
      }
    }

    if let traceDir {
      anyMode = true
      let metrics = try TraceMetricsAggregator.run(traceDir: traceDir)
      print("== Level 4 trace metrics ==")
      printTraceMetrics(metrics)
      if writeBaseline {
        try Baseline.writeTraceMetrics(metrics, into: baselinePath, current: baseline)
        print("PerfParser: wrote Level 4 baseline to \(baselinePath)")
      } else {
        let pass = compareTraceMetrics(metrics, baseline: baseline)
        if !pass { anyFail = true }
      }
    }

    if !anyMode {
      stderr("PerfParser: at least one of --xcresult or --trace-dir is required")
      return 1
    }

    return anyFail ? 2 : 0
  } catch let error as PerfParserError {
    stderr("PerfParser: \(error.message)")
    return 1
  } catch {
    stderr("PerfParser: unexpected error: \(error.localizedDescription)")
    return 1
  }
}

let exitCode = await runMain()
exit(exitCode)
