import Foundation
import SwiftData
import Synchronization
import Testing

@testable import Feeder

// MARK: - C3 read-starvation measurement suite (issue #138 PR A)
//
// Pre-registered measurement that RESOLVES the disposition: does a dense
// cold-start / large-sync write burst saturate the shared SwiftData coordinator
// and starve the article-list read (REAL), or not (BENIGN)? This suite ships
// the TOOLING + the VERDICT; the product fix (if REAL) is PR B.
//
// HEAVY (tens of minutes at locked params): gated OFF the `make test-all` fast
// gate two ways — `.enabled(if: FEEDER_C3_MEASURE)` self-skip AND
// `-skip-testing` in the Makefile `test` target. Run it with `make c3-measure`.
// `FEEDER_C3_SMOKE=1` runs a fast harness self-check (NOT a verdict).

/// Build the burst pages once — `FeedbinEntry` only constructs through the real
/// decoder (`FeedbinFixtures.entry`), so pre-building keeps yielding
/// allocation-free. IDs sit far above `seedPerfTestData`'s fixture range;
/// `feedId` matches a seeded fixture feed so persist associates cleanly.
func c3BuildPages(entryCount: Int, perPage: Int, idBase: Int, feedId: Int) throws -> [FeedbinEntriesPage] {
  var pages: [FeedbinEntriesPage] = []
  var idx = 0
  while idx < entryCount {
    let count = min(perPage, entryCount - idx)
    var entries: [FeedbinEntry] = []
    for j in 0..<count {
      let id = idBase + idx + j
      entries.append(
        try FeedbinFixtures.entry(
          id: id, feedId: feedId, title: "Burst \(id)",
          content: "<p>Burst article \(id) with <b>content</b> to persist and precompute.</p>",
          url: "https://burst.example.com/\(id)"))
    }
    idx += count
    pages.append(
      FeedbinEntriesPage(entries: entries, hasNextPage: idx < entryCount, totalCount: entryCount))
  }
  return pages
}

/// Seconds since `epoch`.
private func c3Stamp(_ epoch: ContinuousClock.Instant) -> Double {
  c3Seconds(epoch.duration(to: .now))
}

/// Run one repetition of an arm: fresh on-disk WAL container (production
/// journal mode — the real coordinator), seeded fixture, the nav read script
/// concurrent with the arm's write condition. Collects read + write intervals
/// on a shared epoch.
func c3RunRep(
  arm: C3Arm, config: C3Config, writer: DataWriter, reader: DataReader,
  fullPages: [FeedbinEntriesPage], smallPages: [FeedbinEntriesPage]
) async throws -> C3RepResult {
  // Reuse the caller's ONE container; reset + re-seed a fresh fixture so each
  // rep is isolated without churning a new coordinator (crash mitigation).
  try await writer.resetStoreForMeasurement()
  _ = try await writer.seedPerfTestData(
    entryCount: config.fixtureEntries, categoryCount: config.fixtureCategories)

  let epoch = ContinuousClock.now
  let reads = Mutex<[C3Interval]>([])
  let writes = Mutex<[C3Interval]>([])
  let persisted = Mutex<Int>(0)

  // Write task — arm-dependent, cancelled when the nav script finishes.
  let writeTask: Task<Void, Never>? =
    arm == .control
    ? nil
    : Task {
      switch arm {
      case .control:
        break
      case .burst, .yield, .smallPages:
        let pages = (arm == .smallPages) ? smallPages : fullPages
        let fake = FakeSyncFeedbinClient(pages: pages, tnet: config.tnet)
        do {
          for try await page in fake.fetchAllEntryPages(since: nil) {
            if Task.isCancelled { break }
            let ws = c3Stamp(epoch)
            _ = try? await writer.persistEntries(page.entries, unreadIDs: [])
            let we = c3Stamp(epoch)
            writes.withLock { $0.append(C3Interval(start: ws, end: we)) }
            persisted.withLock { $0 += page.entries.count }
            if arm == .yield { await Task.yield() }
          }
        } catch {}
      case .sequential:
        // No prefetch: fetch one page (paying Tnet inline), persist, repeat —
        // the network gap sits BETWEEN persists.
        let fake = FakeSyncFeedbinClient(pages: fullPages, tnet: config.tnet)
        for idx in 0..<fullPages.count {
          if Task.isCancelled { break }
          guard let page = await fake.fetchOnePage(index: idx) else { break }
          let ws = c3Stamp(epoch)
          _ = try? await writer.persistEntries(page.entries, unreadIDs: [])
          let we = c3Stamp(epoch)
          writes.withLock { $0.append(C3Interval(start: ws, end: we)) }
          persisted.withLock { $0 += page.entries.count }
        }
      }
    }

  // Nav script: structural reads cycling the fixture categories, human-paced.
  let cats = config.categories
  for i in 0..<config.navReads {
    let cat = cats[i % cats.count]
    let s = c3Stamp(epoch)
    _ = try? await reader.fetchEntrySections(
      category: cat, folder: nil, showRead: false, cutoffDate: .distantPast)
    let e = c3Stamp(epoch)
    reads.withLock { $0.append(C3Interval(start: s, end: e)) }
    try? await Task.sleep(for: config.navSpacing)
  }

  writeTask?.cancel()
  await writeTask?.value

  let readIntervals = reads.withLock { $0 }
  let writeIntervals = writes.withLock { $0 }
  let persistedCount = persisted.withLock { $0 }
  let throughput: Double = {
    guard persistedCount > 0, let lo = writeIntervals.map(\.start).min(),
      let hi = writeIntervals.map(\.end).max(), hi > lo
    else { return 0 }
    return Double(persistedCount) / (hi - lo)
  }()

  return C3RepResult(reads: readIntervals, writes: writeIntervals, throughput: throughput)
}

/// B_p95 pre-run gate: p95 read latency (ms) on the largest fixture category
/// with NO writes, at production-representative sizes. Averaged over a few reps.
func c3MeasureBaselineP95(config: C3Config, writer: DataWriter, reader: DataReader) async throws
  -> Double
{
  var p95s: [Double] = []
  for _ in 0..<max(3, config.repsControl) {
    try await writer.resetStoreForMeasurement()
    _ = try await writer.seedPerfTestData(
      entryCount: config.fixtureEntries, categoryCount: config.fixtureCategories)
    var durs: [Double] = []
    for _ in 0..<config.navReads {
      let s = ContinuousClock.now
      _ = try? await reader.fetchEntrySections(
        category: config.largestCategory, folder: nil, showRead: false, cutoffDate: .distantPast)
      durs.append(c3Seconds(s.duration(to: .now)) * 1000)
    }
    p95s.append(c3Percentile(durs, 0.95))
  }
  return c3Median(p95s)
}

func c3FormatReport(
  config: C3Config, baselineP95: Double, gatePassed: Bool,
  stats: [C3Arm: C3ArmStats], verdict: C3Verdict, notes: [String]
) -> String {
  var out = "\n===== C3 read-starvation measurement (issue #138 PR A) =====\n"
  out += config.isSmoke ? "MODE: SMOKE (harness self-check — NOT a verdict)\n" : "MODE: FULL (locked pre-registration)\n"
  out += String(
    format:
      "Tnet=%.0fms (LOWER-BOUND transfer floor; a real verdict here = 'real at a lower-bound Tnet')\n",
    c3Seconds(config.tnet) * 1000)
  out +=
    "Fixture: \(config.fixtureEntries) entries / \(config.fixtureCategories) categories; burst \(config.burstEntries) entries; nav \(config.navReads) reads @ \(c3Seconds(config.navSpacing))s\n"
  out += String(
    format: "B_p95 pre-run gate: baseline read p95 = %.1fms vs ≤25ms bar → %@\n",
    baselineP95, gatePassed ? "PASS" : "FAIL (→ INCONCLUSIVE / intrinsic fetch cost)")
  func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
  }
  out +=
    "\n" + pad("arm", 11) + pad("reps", 6) + pad("readP95(ms)", 13) + pad("readP95[IQR]", 18)
    + pad("readMed(ms)", 13) + pad("occ%", 9) + pad("occ[IQR]%", 18) + "thrpt(e/s)\n"
  for arm in C3Arm.allCases {
    guard let s = stats[arm] else { continue }
    out += pad(arm.rawValue, 11)
    out += pad("\(s.reps)", 6)
    out += pad(String(format: "%.1f", s.readP95Ms), 13)
    out += pad(String(format: "[%.1f,%.1f]", s.readP95Band.q1, s.readP95Band.q3), 18)
    out += pad(String(format: "%.1f", s.readMedianMs), 13)
    out += pad(String(format: "%.1f", s.occupancy * 100), 9)
    out += pad(
      String(format: "[%.1f,%.1f]", s.occupancyBand.q1 * 100, s.occupancyBand.q3 * 100), 18)
    out += String(format: "%.0f\n", s.throughput)
  }
  out +=
    "\nOccupancy (arch-confirmed) = Σ(structural-reload ∩ burst-window) / burst-window duration — 'how much of the sync is the user watching the spinner'. Numerator clips each loading interval to the window; NOT per-write-overlap-gated (kept distinct from the LOCK-4 in-burst gate).\n"
  out += "\nVERDICT: \(verdict.rawValue)\n"
  for n in notes { out += "  - \(n)\n" }
  out += "============================================================\n"
  return out
}

@Suite("C3 read-starvation measurement")
struct C3ReadStarvationMeasurementTests {
  /// Gated: runs only under `FEEDER_C3_MEASURE=1` (the `make c3-measure`
  /// target). Skipped in `make test-all`. Prints the numbers table + the
  /// computed disposition; the `#expect`s guard only that the harness produced
  /// data — the VERDICT is the reported deliverable, never a pass/fail bias.
  @Test(
    "Measure + resolve the C3 disposition",
    .enabled(if: ProcessInfo.processInfo.environment["FEEDER_C3_MEASURE"] == "1"))
  func measureDisposition() async throws {
    let config = C3Config.resolve()
    let fullPages = try c3BuildPages(
      entryCount: config.burstEntries, perPage: config.perPage, idBase: 1_000_000, feedId: 9000)
    let smallPages = try c3BuildPages(
      entryCount: config.burstEntries, perPage: config.smallPerPage, idBase: 2_000_000, feedId: 9000)

    // ONE on-disk WAL container reused across the baseline gate + every arm/rep
    // (reset between reps). Creating a fresh container per rep churns Core Data
    // coordinators and flakily crashes the long test host; one reused container
    // is the shape `DataReaderConcurrencyTests` proves safe under heavy
    // concurrent read+write.
    let container = try DataWriterTestSupport.makeOnDiskContainer()
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
    let reader = await DataReader.makeDetached(modelContainer: container)

    let baselineP95 = try await c3MeasureBaselineP95(config: config, writer: writer, reader: reader)
    let gatePassed = baselineP95 <= 25.0

    var stats: [C3Arm: C3ArmStats] = [:]
    for arm in C3Arm.allCases {
      let reps: Int
      switch arm {
      case .control: reps = config.repsControl
      case .burst: reps = config.repsBurst
      case .yield, .sequential, .smallPages: reps = config.repsFix
      }
      var repResults: [C3RepResult] = []
      for _ in 0..<reps {
        repResults.append(
          try await c3RunRep(
            arm: arm, config: config, writer: writer, reader: reader,
            fullPages: fullPages, smallPages: smallPages))
      }
      stats[arm] = C3ArmStats.aggregate(arm: arm, repResults: repResults)
    }

    let control = try #require(stats[.control])
    let burst = try #require(stats[.burst])
    let (verdict, _, _, notes) = c3ComputeVerdict(
      C3VerdictInputs(control: control, burst: burst, bP95GatePassed: gatePassed))

    print(
      c3FormatReport(
        config: config, baselineP95: baselineP95, gatePassed: gatePassed,
        stats: stats, verdict: verdict, notes: notes))

    // Harness sanity — NOT a verdict bias.
    #expect(control.reps == config.repsControl)
    #expect(burst.reps == config.repsBurst)
    for arm in [C3Arm.yield, .sequential, .smallPages] {
      #expect(stats[arm]?.reps == config.repsFix)
    }
    #expect(burst.throughput > 0, "burst arm must have persisted pages")
  }
}
