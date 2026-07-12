import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - Sidebar nav direction

/// Direction for the perf scenario's keyboard-nav walk. Maps onto the app's
/// J (next) / K (previous) sidebar shortcuts so the runner exercises the real
/// `bareKeyActions` handler — per-keystroke `sidebarItems → visibleFolderGroups
/// → inFolder` recompute plus `panelFocus` resolution — rather than writing
/// `selection` directly and skipping that work.
///
/// `nonisolated` + `Sendable` so it crosses the runner's closure boundary
/// without isolation friction; it is an immutable tag.
nonisolated enum SidebarNavDirection: Sendable {
  case next
  case previous
}

// MARK: - Perf scenario runner

/// Drives a deterministic keyboard + mouse navigation sequence against the
/// running app so `xctrace record` can capture the production code path under
/// realistic contention: a background write-pressure task hammers the store
/// (matching the currently-selected `@Query` predicate) WHILE the user
/// navigates with J/K and clicks articles. This reproduces the felt keyboard-
/// nav stutter so the Level 4 parser can measure it. Used by the headless perf
/// suite (`make perf`); a no-op when `FEEDER_PERF_MODE` is unset.
///
/// **What this measures vs. what it does not** — the write-pressure proxy
/// exercises the background-write ↔ `@Query`/re-render MainActor contention
/// only. It does NOT reproduce Foundation Models inference-CPU contention, so
/// a green gate here must not be read as "classification-concurrent nav is
/// fine". See the PR body and `Tests/PerfBaselines/README.md`.
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

  // MARK: - Write-pressure tuning

  /// Rows inserted per write-pressure save. A single save touches the
  /// DataWriter actor, then the runner bumps the visible list on MainActor —
  /// so the batch size trades off save cost against bump frequency.
  private static let writePressureBatchSize = 50

  /// Maximum number of write-pressure batches. FIXED count (not duration) so
  /// the induced work is reproducible run to run; the nav walk finishing first
  /// cancels the remainder (cancel-awaited before exit). Large enough that the
  /// pressure stays CONTINUOUS across the whole nav window with no idle gap.
  private static let writePressureMaxBatches = 60

  /// First `feedbinEntryID` for pressure rows. Sits far above
  /// `seedPerfTestData`'s range (10_000 ..< 10_000 + datasetSize) so the
  /// `.unique` attribute never collides.
  private static let writePressureStartingID = 1_000_000

  // MARK: - Nav walk tuning

  /// Number of keyboard-nav steps in the interleaved walk. Every fourth step
  /// also drives a mouse article selection + reader-mode toggle.
  private static let navWalkSteps = 24

  /// Gap between nav steps. Short enough that many keystrokes overlap the
  /// continuous write pressure inside the window, long enough that `xctrace`
  /// samples land on each keystroke's main-thread work.
  private static let navStepGap: Duration = .milliseconds(200)

  // MARK: - Run

  /// Run the scenario end-to-end against the live app:
  /// 1. seed the deterministic dataset on `DataWriter` (BEFORE the window);
  /// 2. wait for the first frame (BEFORE the window);
  /// 3. START an owned, cancellable, fixed-count write-pressure `Task`;
  /// 4. WHILE it runs, drive the interleaved keyboard + mouse nav walk,
  ///    bracketed by the `perf-nav-window` signpost interval;
  /// 5. `cancel()` the write-pressure task and `await` its value (no
  ///    fire-and-forget — `STACK.md § 9`);
  /// 6. flush pending reads, then `exit(0)` so `xctrace` finalises the trace.
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
      // Seeding failure is fatal — the trace would otherwise capture an
      // empty timeline and the parser would compare against junk numbers.
      logger.error("Perf seeding failed: \(error.localizedDescription, privacy: .public)")
      exit(EXIT_FAILURE)
    }

    // Let the first frame paint and the unread snapshot refresh task land.
    // This happens BEFORE the window opens, so cold start is excluded.
    try? await Task.sleep(for: .milliseconds(500))

    // Establish an initial selection before the window so the first pressure
    // batch has a real target and the nav walk starts from a known row.
    navigate(.next)

    // (3) Start the owned, cancellable write-pressure task. Held in a local so
    // it is cancel-awaited before exit — never fire-and-forget.
    let writePressureTask = Task { @MainActor in
      await runWritePressure(
        writer: writer,
        currentSelection: currentSelection,
        bumpEntryList: bumpEntryList
      )
    }

    // (4) Drive the interleaved nav walk inside the measured window.
    let window = perfSignposter.beginInterval(PerformanceSignpostName.perfNavWindow)
    await driveNavWalk(
      apply: apply,
      visibleEntryIDs: visibleEntryIDs,
      navigate: navigate,
      currentSelection: currentSelection
    )
    // Let trailing signpost / render intervals close before ending the window.
    try? await Task.sleep(for: .milliseconds(300))
    perfSignposter.endInterval(PerformanceSignpostName.perfNavWindow, window)

    // (5) Stop write pressure and wait for it to unwind — structured, owned,
    // cancel-awaited (`STACK.md § 7 / § 9`).
    writePressureTask.cancel()
    await writePressureTask.value

    // (6) Flush reads and exit so xctrace finalises the trace.
    await syncEngine.pushPendingReads()
    logger.info("Perf scenario complete; exiting")
    exit(EXIT_SUCCESS)
  }

  // MARK: - Write pressure

  /// Continuously insert fixed-count batches that match the live sidebar
  /// selection's `@Query` predicate, bumping the visible list after each so
  /// its `.task(id:)` refetch fires — the coupling that starves the MainActor
  /// while the user navigates. Loops until the fixed batch count is reached or
  /// the task is cancelled (nav walk finished first). No `Task.sleep` between
  /// batches: the DataWriter `await` is the only suspension, keeping the
  /// pressure continuous with no idle gap for interleaving jitter to return.
  private static func runWritePressure(
    writer: DataWriter,
    currentSelection: @MainActor () -> SidebarSelection?,
    bumpEntryList: @MainActor () -> Void
  ) async {
    var nextID = writePressureStartingID
    var batch = 0
    while batch < writePressureMaxBatches, !Task.isCancelled {
      // Target the row the user is looking at; fall back to a known-seeded
      // leaf category so the very first batch (before any nav) is still
      // targeted and the pressure stays continuous.
      let selection = currentSelection() ?? .category("perf_0")
      nextID =
        (try? await writer.seedPerfTestBatch(
          count: writePressureBatchSize,
          matching: selection,
          startingID: nextID
        )) ?? nextID
      guard !Task.isCancelled else { return }
      // Force the visible list's refetch + re-render on MainActor — the same
      // path sync/classification drains use in production.
      bumpEntryList()
      batch += 1
    }
  }

  // MARK: - Nav walk

  /// Deterministic interleaved walk: keyboard J/K sidebar moves (the real
  /// `bareKeyActions` handler) with a mouse article selection + reader-mode
  /// toggle every fourth step so the detail-render path is exercised under
  /// load too. Fixed step count so the window is reproducible.
  private static func driveNavWalk(
    apply: @MainActor (SidebarSelection?, PersistentIdentifier?, ArticleViewMode) -> Void,
    visibleEntryIDs: @MainActor () -> [PersistentIdentifier],
    navigate: @MainActor (SidebarNavDirection) -> Void,
    currentSelection: @MainActor () -> SidebarSelection?
  ) async {
    for step in 0..<navWalkSteps {
      // Mostly move forward; a periodic backward move exercises both
      // directions of the sidebar recompute.
      let direction: SidebarNavDirection = step.isMultiple(of: 6) && step > 0 ? .previous : .next
      navigate(direction)
      try? await Task.sleep(for: navStepGap)

      // Every fourth step, drive a mouse article selection on the currently
      // visible list, then toggle reader mode and back to exercise the HTML
      // renderer while write pressure churns the store.
      if step.isMultiple(of: 4), let first = visibleEntryIDs().first,
        let selection = currentSelection()
      {
        apply(selection, first, .web)
        try? await Task.sleep(for: navStepGap)
        apply(selection, first, .reader)
        try? await Task.sleep(for: navStepGap)
        apply(selection, first, .web)
        try? await Task.sleep(for: navStepGap)
        // Select the LAST fetched row too (issue #151): this drives the
        // keyboard lazy-append trigger, so the capped-window growth path
        // (grown-prefix refetch under write pressure) executes in the
        // recorded leg — the reference dataset seeds ~400+ rows per
        // category, well past the initial cap, so appends have room to fire.
        if let last = visibleEntryIDs().last {
          apply(selection, last, .web)
          try? await Task.sleep(for: navStepGap)
        }
      }
    }
  }
}
