import Foundation

// MARK: - PerfParser entry point

/// CLI for the headless perf suite. Two input modes can be combined:
///
/// - **`--xcresult <path>`** (Levels 1 + 2): extract XCTest measurements
///   from a single XCResult bundle produced by
///   `xcodebuild test-without-building -only-testing:FeederTests/PerfSignpostTests
///   -only-testing:FeederTests/MicroBenchmarkTests`.
///   `XCTOSSignpostMetric` medians feed Level 2; `XCTPerformanceMetric_WallClockTime`
///   medians feed Level 1.
/// - **`--trace-dir <dir>`** (Level 4): shell out to `xcrun xctrace export`
///   for each `.trace` under the given directory, take per-metric medians
///   across iterations, then either compare against the baseline JSON or
///   overwrite the baseline.
///
/// `--write-baseline` records both Level 1 and Level 2 medians into the
/// baseline document when an `--xcresult` is provided; otherwise it
/// records Level 4 medians from the `--trace-dir` input.
///
/// Exit codes:
/// - `0` — comparison passed (or `--write-baseline` succeeded).
/// - `2` — comparison failed.
/// - `1` — internal error: missing input, missing schema, parse failure.
///
/// All failures bail with a clear stderr message naming what was missing —
/// no silent green per the perf-suite design.

@main
struct PerfParserMain {
  static func main() async {
    let exitCode = await runMain()
    exit(exitCode)
  }
}

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
      let signpostMedians = try await SignpostMetricsExtractor.run(xcresultPath: xcresultPath)
      print("== Level 2 signpost medians ==")
      printSignpostMedians(signpostMedians)
      let microMedians = try await MicroBenchmarkMetricsExtractor.run(xcresultPath: xcresultPath)
      print("== Level 1 micro-benchmark medians ==")
      printMicroBenchmarkMedians(microMedians)
      if writeBaseline {
        try Baseline.writeSignpostMedians(
          signpostMedians, into: baselinePath, current: baseline)
        let afterL2 = try loadBaseline(at: baselinePath)
        try Baseline.writeMicroBenchmarkMedians(
          microMedians, into: baselinePath, current: afterL2)
        print("PerfParser: wrote Level 1 + Level 2 baselines to \(baselinePath)")
      } else {
        let l2Pass = compareSignpostMedians(signpostMedians, baseline: baseline)
        let l1Pass = compareMicroBenchmarkMedians(microMedians, baseline: baseline)
        if !l2Pass || !l1Pass { anyFail = true }
      }
    }

    if let traceDir {
      anyMode = true
      let metrics = try TraceMetricsAggregator.run(traceDir: traceDir)
      print("== Level 4 trace metrics ==")
      printTraceMetrics(metrics)
      if writeBaseline {
        // Re-read the baseline so an in-process write earlier in this
        // invocation (Levels 1 + 2 above) is reflected when Level 4
        // medians are merged in.
        let refreshed = try loadBaseline(at: baselinePath)
        try Baseline.writeTraceMetrics(metrics, into: baselinePath, current: refreshed)
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
