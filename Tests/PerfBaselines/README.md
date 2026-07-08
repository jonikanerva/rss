# Perf Baselines

Headless performance regression baselines for `make perf`.

## Files

- `baseline-current.json` — active baseline used by `make perf`. Level 4
  thresholds (the four absolute fields under `level4_trace`) are populated
  from the diagnosis run captured before the perf refactor landed. Level 2
  signpost medians under `level2_signposts` start as `null` and are
  populated after the user hand-verifies the architectural fix with Time
  Profiler. Level 1 function-level microbenchmarks (under
  `level1_microbench.entries`) shipped in PR 4 — each entry holds
  `{ "median_ms": <value or null> }`. First-run values are captured on
  the boss's next `make perf-record-baseline` invocation; `make perf`
  reads the same xcresult bundle and compares captured medians against
  `baseline × (1 + tolerance_pct/100)`.

## Usage

```bash
# Hand-verify the architectural fix first (Instruments → Time Profiler).
# Then capture / refresh the baseline from the current build:
make perf-record-baseline

# After the baseline is captured, every subsequent run compares against it:
make perf
```

## Nav-stutter measurement (keyboard-nav under write pressure)

The Level 4 scenario also measures the felt keyboard-nav / concurrent-stutter
symptom. `PerfScenarioRunner` (perf-mode only) brackets an interleaved
keyboard J/K + mouse-selection walk in a `perf-nav-window` os_signpost
interval while a fixed-count, cancel-awaited write-pressure task inserts rows
that match the currently-selected item's `@Query` predicate — forcing the
middle pane's refetch + re-render on the MainActor while the user navigates.
Seeding and cold start happen BEFORE the interval, so they are excluded.

The parser resolves the `perf-nav-window` interval `[start, end]` from the
os-signpost table and windows the hang counts to it:

- `microhangs_in_nav_window` / `full_hangs_in_nav_window` — hangs whose
  start-time falls inside the nav window. This is the readable under-load
  stutter signal, with the once-per-launch cold-start hang excluded.
- `sidebar_nav_getter_pct` — inclusive main-thread sample share of the
  sidebar-nav recompute symbols (`sidebarItems` / `visibleFolderGroups` /
  `sidebarNavigationItems`) — the per-keystroke J/K work.

The whole-trace `microhangs_ge_250ms_count` / `full_hangs_ge_500ms_count` are
kept too (unwindowed), for continuity with the pre-nav-window baseline.

**Report-only until the fix is verified (Guard #1).** All hang metrics
(whole-trace and windowed) and `sidebar_nav_getter_pct` ship with a **null
`max`** — the comparator SKIPs them (report-only). We do NOT run
`perf-record-baseline` for this engineered scenario on the current build: that
would bless the sluggishness into the ceiling. The raw first-run under-load
numbers go in the PR body for human sign-off; the baseline is deferred until
AFTER the real fix is Time-Profiler-verified. **Interim gate-coverage gap:**
only `contentview_body_getter_pct` (≤ 9 %) and
`contentview_unread_entries_getter_pct` (≤ 0.1 %) actively gate in the
meantime; a hang regression is visible in the report but does not fail the
gate yet.

**Proxy scope (Guard #4).** The write-pressure task exercises background-write
↔ `@Query`/re-render MainActor contention ONLY. It does NOT reproduce
Foundation Models inference-CPU contention. A green gate must not be read as
"classification-concurrent nav is fine". Human sign-off must also confirm the
induced stutter REPRODUCES the felt symptom (mechanism validation), not just
eyeball the numbers.

**Keyboard residual (Guard #6).** The scenario drives `bareKeyActions.onJ/onK`
directly, which exercises the per-keystroke `sidebarItems → visibleFolderGroups
→ inFolder` recompute + `panelFocus` resolution, but MISSES NSEvent → SwiftUI
key dispatch, `List` scroll-to-selection, and `@FocusState` propagation timing.
Reaching those needs a separate XCUITest / CGEvent scenario (not in this
harness).

**Launch identity (distinct perf bundle).** `xctrace --launch` normalises an
executable path back to its `.app` and resolves the bundle id through
LaunchServices — so the launched binary is whatever LaunchServices deems
canonical for that id, not necessarily the path passed. When the project is
open in Xcode, Xcode keeps a **Debug** build registered for the shipping
`com.feeder.app` id, which wins resolution and makes xctrace trace STALE code
(no `perf-nav-window` interval; symbols in `Feeder.debug.dylib`). To make the
harness honest in the normal (Xcode-open) dev environment, the perf/trace
build ships under a DISTINCT bundle id `com.feeder.app.perf` and installs as
`FeederPerf.app` (`make install-perf`), so resolution is unambiguous. Perf
runs therefore never overwrite the daily `/Applications/Feeder.app`. The
parser still FAILS CLOSED with a clear message if the `perf-nav-window`
interval is ever absent, so a mis-launch can never pass silently.

## Threshold policy

Per-metric, not global ±X:

- `microhangs_ge_250ms_count` / `full_hangs_ge_500ms_count`: report-only
  (null `max`) — see the nav-stutter section above.
- `microhangs_in_nav_window` / `full_hangs_in_nav_window`: report-only
  (null `max`).
- `sidebar_nav_getter_pct`: report-only (null `max`).
- `contentview_body_getter_pct`: absolute ≤ 9 % of total samples.
- `contentview_unread_entries_getter_pct`: absolute ≤ 0.1 % (effectively the
  symbol should be gone).
- Level 1 micro-benchmark medians: ≤ baseline × (1 + `tolerance_pct`/100).
  Shared `tolerance_pct = 20` matches Level 2 — drifts under 20 % are
  noise; drifts above 20 % deserve investigation. The four shipped
  entries (`fetchUnreadCountsSnapshot_micro`,
  `fetchEntrySections_category_micro`, `parseHTMLToBlocks_micro`,
  `groupEntriesByDay_micro`) cover the hot-path functions identified
  during PR 4 planning. New benchmarks added under
  `FeederTests/MicroBenchmarkTests` are picked up automatically by the
  extractor; the first `make perf-record-baseline` invocation after the
  benchmark is added captures the baseline value.
- Level 2 signpost medians: ≤ baseline × 1.20, and `sidebar-click` /
  `article-click` also subject to the 8.3 ms ProMotion hard ceiling per
  `STACK.md` § 4.

## Threshold rationale

- **Whole-trace hang counts are now report-only (null `max`).** They were
  previously gated (`full_hangs_ge_500ms_count` max = 1 for the
  once-per-launch cold-start hang; `microhangs_ge_250ms_count` max = 5). The
  nav-stutter harness supersedes that gate: the meaningful signal is the
  *windowed* count (`*_in_nav_window`), which excludes cold start by
  construction, and per Guard #1 no hang ceiling is blessed until the real fix
  is Time-Profiler-verified. Both whole-trace counts are retained as
  report-only numbers for continuity with the pre-nav-window baseline.
- **`contentview_body_getter_pct` max = 9 %.** The pre-fix diagnosis run
  hit 33.8 %. Anything > 9 % means the `body` re-eval path is doing too
  much work — the architectural rule that body must not aggregate.
- **`contentview_unread_entries_getter_pct` max = 0.1 %.** The symbol
  should not appear at all after the `@Query unreadEntries → cached
  snapshot` refactor; a captured 0 % is the expected steady state.

## Host keying

The baseline is captured on a single host. `make perf` refuses to compare
against a baseline whose `captured_host_cpu` does not match the running
machine's `sysctl -n machdep.cpu.brand_string`. If you change machines,
re-run `make perf-record-baseline` after verifying the fix on the new
host.

## Notes

Generated and consumed by `Tools/PerfParser` (Swift SPM executable). The
parser uses `Foundation.XMLParser` against `xctrace export` output and
`JSONSerialization` against `xcresulttool get test-results tests --format json`
output for Levels 1 + 2 — no Python, no third-party dependencies (per
`STACK.md` § 6). Unit tests for the parser's Level 1 extractor +
comparator + Codable round-trip live in
`Tools/PerfParser/Tests/PerfParserTests` and run via
`swift test --package-path Tools/PerfParser`.

Filed as `[follow-up]` issues:

- _none open_ — Level 1 function-level micro-benchmarks landed in PR 4
  (`feat: perf infrastructure + hot-path offload + script cleanup`),
  superseding the original "Phase 2 perf suite" follow-up per the boss's
  PR-4 decision that performance evidence is foundational, not deferred.
