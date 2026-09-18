import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - Sidebar nav direction

/// Direction for the perf scenario's keyboard walk. It maps onto the J and K
/// sidebar shortcuts, so the runner exercises the real key handler and pays the
/// per-keystroke recompute instead of writing `selection` directly.
nonisolated enum SidebarNavDirection: Sendable {
  case next
  case previous
}

// MARK: - Perf scenario runner

/// Drives a deterministic keyboard and mouse navigation sequence against the
/// running app, so a trace captures the production code path under contention:
/// a write-pressure task hammers the store while the walk navigates and opens
/// articles. A no-op when the perf-mode flag is unset.
///
/// The write-pressure proxy exercises background-write against re-render
/// contention only. It does not reproduce inference-CPU contention, so a green
/// gate here does not say that classification-concurrent navigation is fine.
///
/// `@MainActor`, because every mutation goes through SwiftUI state. The runner
/// only sleeps between writes; the store work stays off MainActor.
@MainActor
enum PerfScenarioRunner {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "PerfScenarioRunner")

  /// True when the launch must run the perf scenario. With the variable unset,
  /// the app stays on its normal credential path.
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["FEEDER_PERF_MODE"] == "1"
  }

  /// Seeded dataset size. The default is the suite's reference scenario; a fast
  /// feedback run may shrink it.
  static var datasetSize: Int {
    guard let raw = ProcessInfo.processInfo.environment["FEEDER_PERF_DATASET_SIZE"],
      let parsed = Int(raw), parsed > 0
    else { return 5000 }
    return parsed
  }

  // MARK: - Write-pressure tuning

  /// Rows inserted per write-pressure save. The size trades save cost against
  /// how often the runner bumps the visible list.
  private static let writePressureBatchSize = 50

  /// Maximum number of write-pressure batches. A fixed count, not a duration,
  /// so the induced work is reproducible; the walk finishing first cancels the
  /// remainder. Large enough to keep the pressure continuous across the whole
  /// window.
  private static let writePressureMaxBatches = 60

  /// First `feedbinEntryID` for pressure rows. It must stay far above the
  /// seeded range, or the `.unique` attribute collides.
  private static let writePressureStartingID = 1_000_000

  // MARK: - Nav walk tuning

  /// Keyboard steps in the interleaved walk. Every fourth step also drives an
  /// article selection and a reader-mode toggle.
  private static let navWalkSteps = 24

  /// Gap between steps: short enough that many keystrokes overlap the write
  /// pressure, long enough that the sampler lands on each keystroke's
  /// main-thread work.
  private static let navStepGap: Duration = .milliseconds(200)

  // MARK: - Run

  /// Run the scenario end-to-end against the live app. Seeding and the first
  /// frame must complete before the measured window opens, so cold start stays
  /// out of it. The write-pressure task is owned and cancel-awaited, never
  /// fire-and-forget (`STACK.md § 9`), and the run ends in `exit(0)` so the
  /// trace is finalised.
  static func run(
    writer: DataWriter,
    syncEngine: SyncEngine,
    apply: @escaping @MainActor (SidebarSelection?, PersistentIdentifier?, ArticleViewMode) -> Void,
    visibleEntryIDs: @escaping @MainActor () -> [PersistentIdentifier],
    navigate: @escaping @MainActor (SidebarNavDirection) -> Void,
    bumpEntryList: @escaping @MainActor () -> Void,
    currentSelection: @escaping @MainActor () -> SidebarSelection?
  ) async {
    logger.info("Perf scenario starting; datasetSize=\(datasetSize, privacy: .public)")
    do {
      _ = try await writer.seedPerfTestData(entryCount: datasetSize)
    } catch {
      // Seeding failure is fatal: the trace would capture an empty timeline
      // and the parser would compare against junk numbers.
      logger.error("Perf seeding failed: \(error.localizedDescription, privacy: .public)")
      exit(EXIT_FAILURE)
    }

    // Let the first frame paint and the snapshot refresh land, before the
    // window opens, so cold start stays out of the measurement.
    try? await Task.sleep(for: .milliseconds(500))

    // Establish a selection before the window, so the first pressure batch has
    // a real target and the walk starts from a known row.
    navigate(.next)

    // Held in a local, so the task is cancel-awaited before exit.
    let writePressureTask = Task { @MainActor in
      await runWritePressure(
        writer: writer,
        currentSelection: currentSelection,
        bumpEntryList: bumpEntryList
      )
    }

    // Drive the interleaved walk inside the measured window.
    let window = perfSignposter.beginInterval(PerformanceSignpostName.perfNavWindow)
    await driveNavWalk(
      apply: apply,
      visibleEntryIDs: visibleEntryIDs,
      navigate: navigate,
      currentSelection: currentSelection
    )
    // Let trailing render intervals close before the window ends.
    try? await Task.sleep(for: .milliseconds(300))
    perfSignposter.endInterval(PerformanceSignpostName.perfNavWindow, window)

    // Stop the write pressure and wait for it to unwind
    // (`STACK.md § 7 / § 9`).
    writePressureTask.cancel()
    await writePressureTask.value

    // Flush the reads, then exit so the trace is finalised.
    await syncEngine.pushPendingReads()
    logger.info("Perf scenario complete; exiting")
    exit(EXIT_SUCCESS)
  }

  // MARK: - Write pressure

  /// Insert batches matching the live selection's predicate and bump the
  /// visible list after each one, so its refetch fires. Loops until the batch
  /// count is reached or the task is cancelled. No sleep between batches: the
  /// writer `await` is the only suspension, which keeps the pressure continuous.
  private static func runWritePressure(
    writer: DataWriter,
    currentSelection: @MainActor () -> SidebarSelection?,
    bumpEntryList: @MainActor () -> Void
  ) async {
    var nextID = writePressureStartingID
    var batch = 0
    while batch < writePressureMaxBatches, !Task.isCancelled {
      // Target the current selection, and fall back to a seeded leaf category
      // so the first batch is targeted too.
      let selection = currentSelection() ?? .category("perf_0")
      nextID =
        (try? await writer.seedPerfTestBatch(
          count: writePressureBatchSize,
          matching: selection,
          startingID: nextID
        )) ?? nextID
      guard !Task.isCancelled else { return }
      // Force the visible list's refetch and re-render on MainActor, the same
      // path the production drains use.
      bumpEntryList()
      batch += 1
    }
  }

  // MARK: - Nav walk

  /// Deterministic interleaved walk: real J/K sidebar moves, with an article
  /// selection and a reader-mode toggle every fourth step so the detail-render
  /// path runs under load too. Fixed step count, so the window is reproducible.
  private static func driveNavWalk(
    apply: @MainActor (SidebarSelection?, PersistentIdentifier?, ArticleViewMode) -> Void,
    visibleEntryIDs: @MainActor () -> [PersistentIdentifier],
    navigate: @MainActor (SidebarNavDirection) -> Void,
    currentSelection: @MainActor () -> SidebarSelection?
  ) async {
    for step in 0..<navWalkSteps {
      // A periodic backward move exercises both directions of the sidebar
      // recompute.
      let direction: SidebarNavDirection = step.isMultiple(of: 6) && step > 0 ? .previous : .next
      navigate(direction)
      try? await Task.sleep(for: navStepGap)

      // Select an article, then toggle reader mode and back, so the HTML
      // renderer runs while write pressure churns the store.
      if step.isMultiple(of: 4), let first = visibleEntryIDs().first,
        let selection = currentSelection()
      {
        apply(selection, first, .web)
        try? await Task.sleep(for: navStepGap)
        apply(selection, first, .reader)
        try? await Task.sleep(for: navStepGap)
        apply(selection, first, .web)
        try? await Task.sleep(for: navStepGap)
      }
    }
  }
}
