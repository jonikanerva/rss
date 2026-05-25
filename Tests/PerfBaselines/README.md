# Perf Baselines

Headless performance regression baselines for `make perf`.

## Files

- `baseline-current.json` — active baseline used by `make perf`. Level 4
  thresholds (the four absolute fields under `level4_trace`) are populated
  from the diagnosis run captured before the perf refactor landed. Level 2
  signpost medians under `level2_signposts` start as `null` and are
  populated after the user hand-verifies the architectural fix with Time
  Profiler.

## Usage

```bash
# Hand-verify the architectural fix first (Instruments → Time Profiler).
# Then capture / refresh the baseline from the current build:
make perf-record-baseline

# After the baseline is captured, every subsequent run compares against it:
make perf
```

## Threshold policy

Per-metric, not global ±X:

- `microhangs_ge_250ms_count`: absolute ≤ 5.
- `full_hangs_ge_500ms_count`: absolute ≤ 1.
- `contentview_body_getter_pct`: absolute ≤ 9 % of total samples.
- `contentview_unread_entries_getter_pct`: absolute ≤ 0.1 % (effectively the
  symbol should be gone).
- Level 2 signpost medians: ≤ baseline × 1.20, and `sidebar-click` /
  `article-click` also subject to the 8.3 ms ProMotion hard ceiling per
  `docs/stack.md` § 4.

## Threshold rationale

- **`full_hangs_ge_500ms_count` max = 1, not 0.** The headless `xctrace
  record --launch /Applications/Feeder.app` scenario starts Feeder fresh
  per iteration: dyld + SwiftUI init + SwiftData container open +
  `seedPerfTestData(5000)` + WebKit XPC spawn cleanly exceeds the 500 ms
  hang threshold exactly once per launch. Median across five iterations
  is therefore a stable `1`, not a regression. A real regression that
  adds a second long hang on the click path still fails the gate (`2 > 1`).
  The original design's `max: 0` assumed an already-warm process driven
  by hand — incompatible with the per-iteration cold-start tax of the
  automated suite.
- **`microhangs_ge_250ms_count` max = 5.** Same cold-start reasoning as
  above plus a small budget for the once-per-launch click sequence;
  the captured value (currently 1) sits well below the ceiling, so the
  gate still catches a drift to 6+.
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
parser uses `Foundation.XMLParser` against `xctrace export` output — no
Python, no third-party dependencies (per `docs/stack.md` § 6).

Filed as `[follow-up]` issues:

- Phase 2 perf suite: function-level micro-benchmarks (Level 1) — deferred
  per devils-advocate's note that predictive wrapping would not have caught
  the architectural regressions this cycle.
