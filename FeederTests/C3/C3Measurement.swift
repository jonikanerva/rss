import Foundation
import SwiftData
import Synchronization

@testable import Feeder

// MARK: - C3 read-starvation measurement support (issue #138)
//
// Pre-registered measurement per arch's locked design. This file holds the
// falsifiable machinery: fixture, arms, interval/overlap math, percentile /
// dispersion stats, and the verdict rule. Nothing here shrinks a threshold to
// pass — the gates are pre-committed.

// MARK: - Configuration

/// Measurement parameters. The DEFAULT values are the LOCKED pre-registration;
/// `FEEDER_C3_SMOKE=1` swaps in tiny params for a fast harness self-check only
/// (never used for the verdict — the suite prints which mode it ran in).
struct C3Config: Sendable {
  let fixtureEntries: Int
  let fixtureCategories: Int
  let burstEntries: Int
  let perPage: Int
  let smallPerPage: Int
  let navReads: Int
  let navSpacing: Duration
  let repsControl: Int
  let repsBurst: Int
  let repsFix: Int
  /// Lower-bound per-page network latency (transfer-only floor). Derivation:
  /// a ~100-entry full-content page ≈ 200 KB, over a generous ~200 Mbit/s
  /// (25 MB/s) broadband link with RTT ≈ 0 ⇒ ~8 ms. A LOWER bound is
  /// worst-case-SAFE (shorter Tnet ⇒ less inter-persist gap ⇒ MORE coordinator
  /// saturation ⇒ benign-here ⇒ benign-everywhere). A REAL verdict at this
  /// floor must be labelled "real at a lower-bound Tnet" (a longer real Tnet
  /// may be less severe) — PR B confirms against a realistic Tnet.
  let tnet: Duration
  let isSmoke: Bool

  static func resolve() -> C3Config {
    let env = ProcessInfo.processInfo.environment
    if env["FEEDER_C3_SMOKE"] == "1" {
      // Tiny — harness self-check only (fast, NOT a verdict).
      return C3Config(
        fixtureEntries: 600, fixtureCategories: 12, burstEntries: 400,
        perPage: 100, smallPerPage: 25, navReads: 8, navSpacing: .milliseconds(150),
        repsControl: 2, repsBurst: 2, repsFix: 2, tnet: .milliseconds(8), isSmoke: true)
    }
    if env["FEEDER_C3_MEDIUM"] == "1" {
      // Full-scale fixture + burst (the real coordinator load) but few reps and
      // tighter pacing — a fast reproduction of any scale-dependent failure
      // before committing to the full run. Marked smoke (NOT a verdict).
      return C3Config(
        fixtureEntries: 6000, fixtureCategories: 12, burstEntries: 5000,
        perPage: 100, smallPerPage: 25, navReads: 12, navSpacing: .milliseconds(700),
        repsControl: 2, repsBurst: 2, repsFix: 2, tnet: .milliseconds(8), isSmoke: true)
    }
    return C3Config(
      fixtureEntries: 6000, fixtureCategories: 12, burstEntries: 5000,
      perPage: 100, smallPerPage: 25, navReads: 30, navSpacing: .milliseconds(1500),
      repsControl: 5, repsBurst: 5, repsFix: 10, tnet: .milliseconds(8), isSmoke: false)
  }

  /// The largest seeded fixture category label (`seedPerfTestData` balances
  /// evenly, so any leaf works; `perf_0` is deterministic).
  var largestCategory: String { "perf_0" }
  /// All seeded leaf-category labels the nav script cycles through.
  var categories: [String] { (0..<fixtureCategories).map { "perf_\($0)" } }
}

// MARK: - Arms

/// The five write conditions. Identical nav script + fixture across all — they
/// differ ONLY in how (or whether) the sync-page write burst runs.
enum C3Arm: String, CaseIterable, Sendable {
  case control = "CONTROL"  // quiet — reads only
  case burst = "BURST"  // unbounded prefetch, back-to-back persists
  case yield = "YIELD"  // BURST + Task.yield between persists
  case sequential = "3a-SEQ"  // no prefetch — fetch page, persist, next
  case smallPages = "3b-SMALL"  // smaller per_page (more, smaller persists)
}

// MARK: - Interval math (shared epoch, seconds)

/// A half-open time interval in seconds since the arm's epoch.
struct C3Interval: Sendable {
  let start: Double
  let end: Double
  var duration: Double { max(0, end - start) }
}

/// Seconds value of a `Duration` (whole + attoseconds).
func c3Seconds(_ d: Duration) -> Double {
  let c = d.components
  return Double(c.seconds) + Double(c.attoseconds) * 1e-18
}

/// True when `interval` overlaps any of `others` — the LOCK-4 in-burst gate
/// (a structural-reload overlapping an active write-persist), used ONLY to
/// select which reloads feed the STALL p95/median. Occupancy does NOT use this.
func c3Overlaps(_ interval: C3Interval, _ others: [C3Interval]) -> Bool {
  for o in others where min(interval.end, o.end) > max(interval.start, o.start) { return true }
  return false
}

// MARK: - Percentile / dispersion

/// Linear-interpolation percentile (`p` in 0...1) over a value sample.
func c3Percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  if sorted.count == 1 { return sorted[0] }
  let rank = p * Double(sorted.count - 1)
  let lo = Int(rank.rounded(.down))
  let hi = Int(rank.rounded(.up))
  let frac = rank - Double(lo)
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
}

func c3Median(_ values: [Double]) -> Double { c3Percentile(values, 0.5) }

/// Interquartile band (25th, 75th) of per-rep statistics — the noise band. Two
/// arms' effects "clear the band" only when their `[q1, q3]` bands are disjoint.
func c3IQR(_ values: [Double]) -> (q1: Double, q3: Double) {
  (c3Percentile(values, 0.25), c3Percentile(values, 0.75))
}

func c3BandsDisjoint(_ a: (q1: Double, q3: Double), _ b: (q1: Double, q3: Double)) -> Bool {
  a.q3 < b.q1 || b.q3 < a.q1
}

// MARK: - Per-rep + per-arm results

/// One repetition's collected intervals + derived per-rep statistics.
struct C3RepResult: Sendable {
  let reads: [C3Interval]
  let writes: [C3Interval]
  /// Structural reads whose interval overlaps an active write-persist.
  var inBurstReads: [C3Interval] { reads.filter { c3Overlaps($0, writes) } }
  /// p95 of in-burst read durations (ms). For CONTROL (no writes) there are no
  /// in-burst reads, so this falls back to the p95 of ALL reads = the baseline.
  var inBurstP95Ms: Double {
    let src = writes.isEmpty ? reads : inBurstReads
    return c3Percentile(src.map { $0.duration * 1000 }, 0.95)
  }
  var inBurstMedianMs: Double {
    let src = writes.isEmpty ? reads : inBurstReads
    return c3Median(src.map { $0.duration * 1000 })
  }
  /// Occupancy (arch's confirmed locked formula, issue #138):
  ///
  ///   Occ = Σ(structural-reload interval ∩ burst-window) / (burst-window duration)
  ///
  /// Numerator: each structural-reload (blank-window: structural key change →
  /// sections replaced) interval CLIPPED to the burst window. Denominator: the
  /// burst window's wall-clock — first write-persist start → last
  /// write-persist end. This is "how much of the sync is the user watching an
  /// unresolved panel-2": fast reads occupy a tiny slice of the long sync
  /// window (low), starved reads occupy most of it (high). 0 for CONTROL (no
  /// burst window).
  ///
  /// Kept DISTINCT from the LOCK-4 in-burst gate (`inBurstReads`): occupancy is
  /// total loading time over the WINDOW and is NEVER per-reload write-gated.
  /// (The earlier bug imported the LOCK-4 overlap notion into occupancy's
  /// numerator, making it trivially ~100% under a continuous burst — arch
  /// confirmed this window-clipped form restores the intended metric.)
  var occupancy: Double {
    guard let lo = writes.map(\.start).min(), let hi = writes.map(\.end).max(), hi > lo else {
      return 0
    }
    // Reads are sequential (no self-overlap), so summing clipped reloads = the
    // union of loading time inside [lo, hi].
    let loadingInWindow = reads.reduce(0.0) { acc, r in
      acc + max(0, min(r.end, hi) - max(r.start, lo))
    }
    return min(loadingInWindow / (hi - lo), 1.0)
  }
  /// Sync throughput (entries/sec) for the write burst, or 0 for CONTROL.
  let throughput: Double
}

/// Aggregated per-arm statistics across reps.
struct C3ArmStats: Sendable {
  let arm: C3Arm
  let reps: Int
  /// Median across reps of per-rep in-burst read p95 (ms), plus its IQR band.
  let readP95Ms: Double
  let readP95Band: (q1: Double, q3: Double)
  let readMedianMs: Double
  /// Median across reps of per-rep occupancy (fraction 0...1), plus IQR band.
  let occupancy: Double
  let occupancyBand: (q1: Double, q3: Double)
  let throughput: Double

  static func aggregate(arm: C3Arm, repResults: [C3RepResult]) -> C3ArmStats {
    let p95s = repResults.map(\.inBurstP95Ms)
    let occs = repResults.map(\.occupancy)
    return C3ArmStats(
      arm: arm,
      reps: repResults.count,
      readP95Ms: c3Median(p95s),
      readP95Band: c3IQR(p95s),
      readMedianMs: c3Median(repResults.map(\.inBurstMedianMs)),
      occupancy: c3Median(occs),
      occupancyBand: c3IQR(occs),
      throughput: c3Median(repResults.map(\.throughput))
    )
  }
}

// MARK: - Verdict (LOCKED rule)

enum C3Verdict: String, Sendable {
  case realSevere = "REAL-SEVERE"  // occupancy gate fires (explains the spinner)
  case realMild = "REAL-MILD"  // only the stall gate fires (does not explain the spinner)
  case benign = "BENIGN"  // neither gate fires
  case inconclusive = "INCONCLUSIVE"  // B_p95 gate failed (intrinsic fetch cost)
}

/// Compute the disposition from CONTROL (baseline) vs BURST, per the locked
/// rule. Effects count only BEYOND the noise band (disjoint IQR) AND clearing
/// the floor. Floors: reads 50 ms, occupancy 10 pp; gate thresholds: stall
/// U_p95 ≥ 100 ms + Δ_read ≥ 50 ms; occupancy Occ ≥ 50% + ΔOcc ≥ 25 pp.
struct C3VerdictInputs: Sendable {
  let control: C3ArmStats
  let burst: C3ArmStats
  let bP95GatePassed: Bool
}

func c3ComputeVerdict(_ i: C3VerdictInputs) -> (verdict: C3Verdict, stallFired: Bool, occFired: Bool, notes: [String]) {
  var notes: [String] = []
  guard i.bP95GatePassed else {
    return (
      .inconclusive, false, false,
      [
        "B_p95 pre-run gate failed — baseline read cost ≈ the 100 ms stall bar; the read is intrinsically expensive at representative sizes, not starved. Report as an intrinsic-fetch-cost finding (→ #139), not a starvation disposition."
      ]
    )
  }

  let deltaReadMs = i.burst.readP95Ms - i.control.readP95Ms
  let readBandsDisjoint = c3BandsDisjoint(i.burst.readP95Band, i.control.readP95Band)
  let stallFired =
    i.burst.readP95Ms >= 100.0
    && deltaReadMs >= 50.0
    && readBandsDisjoint
  notes.append(
    "STALL gate: U_p95(burst,in-burst)=\(String(format: "%.1f", i.burst.readP95Ms))ms (≥100), "
      + "Δ_read=\(String(format: "%.1f", deltaReadMs))ms (≥50), bands disjoint=\(readBandsDisjoint) → \(stallFired ? "FIRES" : "no")")

  let deltaOccPP = (i.burst.occupancy - i.control.occupancy) * 100
  let occBandsDisjoint = c3BandsDisjoint(i.burst.occupancyBand, i.control.occupancyBand)
  let occFired =
    i.burst.occupancy >= 0.50
    && deltaOccPP >= 25.0
    && occBandsDisjoint
  notes.append(
    "OCCUPANCY gate: Occ_burst=\(String(format: "%.1f", i.burst.occupancy * 100))% (≥50), "
      + "ΔOcc=\(String(format: "%.1f", deltaOccPP))pp (≥25), bands disjoint=\(occBandsDisjoint) → \(occFired ? "FIRES" : "no")")

  let verdict: C3Verdict
  if occFired {
    verdict = .realSevere
    notes.append(
      "Occupancy fires ⇒ REAL-SEVERE: read starvation occupies the sync window — explains the near-constant panel-2 spinner. → PR B product fix."
    )
  } else if stallFired {
    verdict = .realMild
    notes.append(
      "Only stall fires ⇒ REAL-MILD: reads slow under burst but do not occupy the window — does NOT explain the near-constant spinner. Issue stays open (intrinsic/other → #139)."
    )
  } else {
    verdict = .benign
    notes.append(
      "Neither gate fires ⇒ BENIGN: the cold-start read does not measurably starve under a large sync at a lower-bound Tnet. The grace-spinner continuity idea becomes admissible."
    )
  }
  return (verdict, stallFired, occFired, notes)
}
