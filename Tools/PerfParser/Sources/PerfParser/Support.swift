import Foundation

// MARK: - Errors

/// Single error domain for the perf parser. Carries a human-readable message
/// so the CLI can print it verbatim to stderr.
struct PerfParserError: Error {
  let message: String
}

// MARK: - I/O helpers

func stderr(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
  let usage = """
    PerfParser — Feeder perf-suite parser

    Usage:
      PerfParser --baseline <path> --xcresult <path>
      PerfParser --baseline <path> --trace-dir <dir> [--write-baseline]
      PerfParser --baseline <path> --xcresult <path> --trace-dir <dir> [--write-baseline]

    Exit codes:
      0   PASS / wrote baseline
      2   FAIL — at least one metric exceeded threshold
      1   internal error (missing input, parse failure)
    """
  print(usage)
}

// MARK: - Process runner

/// Run a subprocess synchronously, returning stdout as Data. Throws on
/// non-zero exit so callers can rely on output validity.
func runProcess(launchPath: String, arguments: [String]) throws -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = arguments
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe
  do {
    try process.run()
  } catch {
    throw PerfParserError(
      message: "failed to launch \(launchPath): \(error.localizedDescription)"
    )
  }
  let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  if process.terminationStatus != 0 {
    let stderrText = String(data: stderrData, encoding: .utf8) ?? "<binary>"
    throw PerfParserError(
      message:
        "\(launchPath) \(arguments.joined(separator: " ")) failed with exit \(process.terminationStatus): \(stderrText)"
    )
  }
  return stdoutData
}

// MARK: - Numeric helpers

extension Array where Element == Double {
  /// Median of a sorted-or-unsorted Double array. Returns nil on empty input.
  func median() -> Double? {
    guard !isEmpty else { return nil }
    let sorted = self.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
  }

  /// 95th-percentile value via nearest-rank. Returns nil on empty input.
  func percentile(_ p: Double) -> Double? {
    guard !isEmpty else { return nil }
    let sorted = self.sorted()
    let rank = Int((p / 100.0 * Double(sorted.count)).rounded(.up)) - 1
    let clamped = Swift.max(0, Swift.min(sorted.count - 1, rank))
    return sorted[clamped]
  }
}
