import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - Perf scenario runner

/// Drives a deterministic click sequence against the running app so
/// `xctrace record` can capture the production code path: sidebar selection
/// → article-list `.task(id:)` → row selection → detail render. Used by the
/// headless perf suite (`make perf`); a no-op when `FEEDER_PERF_MODE` is
/// unset.
///
/// Why MainActor: every mutation here goes through SwiftUI `@State` /
/// `@Binding`, which must be written on MainActor. The runner only sleeps
/// between writes; SwiftData reads/writes still happen off-MainActor inside
/// the existing `DataWriter` and `.task(id:)` modifiers.
@MainActor
enum PerfScenarioRunner {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "PerfScenarioRunner")

  /// True when the launch should run the perf scenario. Production builds with
  /// the env var unset stay on the normal `checkCredentials` path.
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["FEEDER_PERF_MODE"] == "1"
  }

  /// Override for the seeded dataset size. Defaults to 5000 — the suite's
  /// reference scenario. `make perf` may shrink this for fast feedback runs.
  static var datasetSize: Int {
    guard let raw = ProcessInfo.processInfo.environment["FEEDER_PERF_DATASET_SIZE"],
      let parsed = Int(raw), parsed > 0
    else { return 5000 }
    return parsed
  }

  /// Run the scenario end-to-end against the live app:
  /// 1. seed deterministic dataset on `DataWriter`,
  /// 2. wait for the first frame,
  /// 3. drive a three-category / three-article click sequence with 1 s gaps,
  /// 4. flush pending reads, then `exit(0)` so `xctrace` finalises the trace.
  static func run(
    writer: DataWriter,
    syncEngine: SyncEngine,
    apply: @escaping @MainActor (SidebarSelection?, Entry?, ArticleViewMode) -> Void,
    visibleEntries: @escaping @MainActor () -> [Entry]
  ) async {
    logger.info("Perf scenario starting; datasetSize=\(datasetSize, privacy: .public)")
    do {
      _ = try await writer.seedPerfTestData(entryCount: datasetSize)
    } catch {
      // Seeding failure is fatal — the trace would otherwise capture an
      // empty timeline and the parser would compare against junk numbers.
      logger.error("Perf seeding failed: \(error.localizedDescription, privacy: .public)")
      exit(EXIT_FAILURE)
    }

    // Let the first frame paint and the unread snapshot refresh task land.
    try? await Task.sleep(for: .milliseconds(500))

    let folderLabels = ["technology", "world"]
    var clickIndex = 0
    for folderLabel in folderLabels {
      apply(.folder(folderLabel), nil, .web)
      try? await Task.sleep(for: .seconds(1))

      let entries = visibleEntries()
      if let first = entries.first {
        apply(.folder(folderLabel), first, .web)
        try? await Task.sleep(for: .seconds(1))
        // Toggle once into reader mode to exercise the HTML renderer path.
        apply(.folder(folderLabel), first, .reader)
        try? await Task.sleep(for: .seconds(1))
        apply(.folder(folderLabel), first, .web)
      }
      clickIndex += 1
      if clickIndex >= 3 { break }
    }

    // Drive a third sidebar tick against a leaf category so the
    // sidebar-click signpost is captured against both folder and category
    // selections.
    apply(.category("perf_0"), nil, .web)
    try? await Task.sleep(for: .seconds(1))
    let leafEntries = visibleEntries()
    if let first = leafEntries.first {
      apply(.category("perf_0"), first, .web)
      try? await Task.sleep(for: .seconds(1))
    }

    // Let trailing signpost intervals close before tearing down.
    try? await Task.sleep(for: .milliseconds(500))

    await syncEngine.pushPendingReads()

    logger.info("Perf scenario complete; exiting")
    exit(EXIT_SUCCESS)
  }
}
