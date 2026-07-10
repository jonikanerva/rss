#!/usr/bin/env bash
# Launches the Release FeederPerf.app under FEEDER_PERF_MODE=1 inside
# `xctrace record` for N iterations, dropping the first as warm-up. The
# parser then takes per-metric medians across the remaining iterations.
set -euo pipefail

ITERATIONS=5
TIME_LIMIT=20000
OUTPUT_DIR="artifacts/local/perf"
DATASET_SIZE=5000
APP_PATH="/Applications/FeederPerf.app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --time-limit) TIME_LIMIT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --dataset-size) DATASET_SIZE="$2"; shift 2 ;;
    --app-path) APP_PATH="$2"; shift 2 ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: $APP_PATH not found. Run \`make install-perf\` first." >&2
  exit 1
fi

# Resolve the concrete Mach-O to launch. `xctrace record --launch` normalises
# an executable path back to its enclosing `.app` and resolves the launch
# target by EXECUTABLE NAME through LaunchServices, so the launched binary is
# whatever LaunchServices considers canonical for that name — NOT necessarily
# the path passed here. The daily app and every Xcode Debug build share the
# executable name `Feeder`, so a `--launch` of a `Feeder`-named binary can
# hijack to the wrong (stale) build (issue #129). The perf build sidesteps that
# by building under a DISTINCT executable name (`FeederPerf`, via
# `PRODUCT_NAME=FeederPerf` in `make install-perf`): nothing else ever sets that
# name, so every bearer of the `FeederPerf` executable name IS the current perf
# build, and `--launch` resolves to exactly this install — even when the
# shipping `Feeder` is registered by an open Xcode session. (The perf build also
# carries a distinct bundle id, but the EXECUTABLE NAME is what makes `--launch`
# unambiguous.)
#
# The perf app is installed as `FeederPerf.app` with executable `FeederPerf`;
# derive the binary from `CFBundleExecutable` rather than assuming it matches
# the bundle name.
APP_EXECUTABLE="$(defaults read "$APP_PATH/Contents/Info" CFBundleExecutable 2>/dev/null || basename "$APP_PATH" .app)"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
if [[ ! -x "$APP_BINARY" ]]; then
  echo "ERROR: $APP_BINARY not found or not executable. Run \`make install-perf\` first." >&2
  exit 1
fi

# Pattern matching the launched binary inside the bundle. Used with `pkill -f`,
# so it matches the full command line (the binary PATH) and targets the
# FeederPerf.app executable specifically — a stray kill can never hit the user's
# daily `Feeder.app`. `xctrace record --launch` does not always reap the
# launched FeederPerf process when the recording's time-limit elapses (the trace
# closes but the app keeps running in the Dock); across N iterations that piles
# up, so each iteration reaps residuals before and after. `|| true` keeps the
# script alive when there is nothing to kill (the common case on first run).
FEEDER_BINARY_PATTERN="FeederPerf.app/Contents/MacOS/FeederPerf"

kill_residual_feeder_processes() {
  # Send TERM first so anything in-flight can flush cleanly. The brief
  # sleep is bounded so the loop does not stretch out perf runs; KILL
  # follows for stragglers.
  pkill -TERM -f "$FEEDER_BINARY_PATTERN" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "$FEEDER_BINARY_PATTERN" 2>/dev/null || true
}

# The perf app is SANDBOXED, so its SwiftData store lives in a per-bundle-id
# container. Derive the id from the installed app (not hard-coded) so a bundle
# rename can't silently point the reset at the wrong container.
APP_BUNDLE_ID="$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || echo com.feeder.app.perf)"
PERF_STORE_DIR="$HOME/Library/Containers/$APP_BUNDLE_ID/Data/Library/Application Support"

# Reset the perf container store so EVERY iteration launches into an EMPTY
# store and `seedPerfTestData` re-seeds the SAME deterministic 5000-row
# dataset. That seeder guards on an empty store (returns early if data already
# exists), so WITHOUT this reset only the first launch seeds; later iterations
# skip seeding, their write-pressure rows accumulate, and the article list
# degenerates to EMPTY — no detail render, which the parser's render-path floor
# then (correctly) rejects. Deleting only the three SwiftData store files
# (never the container directory) keeps the reset surgical. This is the perf
# CONTAINER store — a sandboxed `com.feeder.app.perf` container, NOT the user's
# real reading DB (a separate `donut.Feeder` container) (issue #132).
reset_perf_store() {
  rm -f "$PERF_STORE_DIR/Feeder.store" \
    "$PERF_STORE_DIR/Feeder.store-shm" \
    "$PERF_STORE_DIR/Feeder.store-wal" 2>/dev/null || true
}

# Fail-loud gate on each iteration's xctrace log — two independent tripwires,
# both catching a class of failure the perf PARSER alone would miss:
#
#   OBJ-1 (launch identity, issue #129): xctrace must report
#   `Launching process: FeederPerf`. The parser only infers a wrong/stale binary
#   from a MISSING `perf-nav-window` interval, so a stale-but-post-#128
#   `FeederPerf` (still emitting signposts) could slip through. Asserting the
#   launched executable name is the durable guard that `--launch` resolved to
#   the perf build, not a hijacked `Feeder`. xctrace itself prints this line, so
#   it is reliably present in the captured log.
#   This guard is now ACTIVE (issue #132). It was previously DORMANT because the
#   scenario never ran to completion under a headless launch, so xctrace
#   time-limited the still-running app and exited non-zero, and `set -e` aborted
#   at the record command BEFORE this check. #132 fixed both ends: the app-side
#   perf-activation delegate makes the scenario render and self-exit `exit(0)`,
#   and `run_iteration` now captures xctrace's status (`|| status=$?`) and runs
#   this assertion regardless of exit code, so it always executes.
#
#   OBJ-2 (container schema-identity tripwire): the perf build is SANDBOXED and
#   opens its OWN container store (~/Library/Containers/com.feeder.app.perf/…,
#   `ModelConfiguration("Feeder")`) — ISOLATED from the user's real reading DB
#   (the daily app is a separate `donut.Feeder` container), so there is NO
#   user-data-wipe hazard. This stays as cheap defense-in-depth: if the module
#   pin (`PRODUCT_MODULE_NAME=Feeder`) ever regressed, or a future change
#   disabled the sandbox so the perf build shared a store, `@Model` could
#   mismatch the store schema and trip FeederApp's store-delete recovery (the
#   `Deleting store and retrying` message). Failing loud keeps the perf
#   CONTAINER store's schema/module identity consistent run to run. CAVEAT: that
#   message is emitted via `os.Logger` (unified log), not stdout, so it may not
#   surface in this captured file — a best-effort tripwire, not a guarantee.
assert_perf_launch() {
  local index="$1"
  local log="$2"
  if ! grep -q "Launching process: FeederPerf" "$log"; then
    echo "ERROR: iteration $index did not launch the FeederPerf build." >&2
    echo "       '$log' has no 'Launching process: FeederPerf' line — xctrace" >&2
    echo "       resolved a wrong/stale binary. Re-run \`make install-perf\` and" >&2
    echo "       retry (issue #129)." >&2
    exit 1
  fi
  if grep -q "Deleting store and retrying" "$log"; then
    echo "ERROR: iteration $index tripped SwiftData store-delete recovery." >&2
    echo "       '$log' contains 'Deleting store and retrying' — the perf build's" >&2
    echo "       @Model identity did NOT match its container store schema. The" >&2
    echo "       module pin (PRODUCT_MODULE_NAME=Feeder) likely regressed, or the" >&2
    echo "       sandbox was disabled so a store is shared. Fix the pin/identity" >&2
    echo "       before re-running (this is the perf container store, not the" >&2
    echo "       user's real reading DB)." >&2
    exit 1
  fi
}

# Register the perf bundle with LaunchServices so `xctrace --launch` resolves
# its distinct EXECUTABLE NAME (`FeederPerf`) to this exact install. Because
# nothing else ever sets `PRODUCT_NAME=FeederPerf`, every bearer of that
# executable name IS the current perf build, so resolution is unambiguous even
# with Xcode open (Xcode only ever builds the shipping `Feeder`). Belt and
# suspenders: `assert_perf_launch` fails loud if xctrace still lands on a
# `Feeder`-named binary, and the parser fails closed if `perf-nav-window` is
# ever absent — a mis-launch can never pass silently.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_PATH" || true
fi

mkdir -p "$OUTPUT_DIR"
# Iteration 0 is warm-up — recorded but ignored by the parser by exclusion
# from the trace-dir naming convention.
WARMUP_DIR=$(mktemp -d)
# Cleanup trap covers the warmup tmpdir AND any residual FeederPerf process
# the user may have left mid-run (Ctrl-C, OOM, or a `xctrace` crash).
# `EXIT` fires on normal exit; `INT TERM` cover user-interrupted runs so
# the boss does not have to hand-kill zombies after a Ctrl-C.
trap "kill_residual_feeder_processes; rm -rf '$WARMUP_DIR'" EXIT INT TERM

run_iteration() {
  local index="$1"
  local out_dir="$2"
  local out_file="$out_dir/iteration-${index}.trace"
  rm -rf "$out_file"
  # Belt-and-suspenders: kill any FeederPerf process left over from the
  # previous iteration before launching the next one. The trace bundle's
  # `--time-limit` does not always reap the launched process, so without
  # this each iteration would stack another FeederPerf in the Dock.
  kill_residual_feeder_processes
  # Fresh store per iteration (after the kill, so no process holds the file):
  # each launch re-seeds the same deterministic dataset and renders the same
  # article list + detail, so every iteration is comparable and the render-path
  # floor is satisfied on all of them (issue #132).
  reset_perf_store
  echo "==> trace iteration $index ($out_file)"
  # `xcrun xctrace record` stops parsing its own flags at `--launch --`;
  # anything after that token is forwarded as argv to the launched app.
  # Keep `--time-limit` and `--output` BEFORE `--launch` so xctrace itself
  # honours them — otherwise it falls back to no time limit and a default
  # `Launch_<App>_<date>_<hash>.trace` filename in the shell's cwd, and the
  # parser sees zero traces in $OUTPUT_DIR.
  # Capture xctrace's own stdout/stderr to a per-iteration log rather than
  # discarding it — a failed launch (bad signature, LaunchServices mis-resolve)
  # otherwise leaves only an opaque non-zero exit. Written under OUTPUT_DIR
  # (which survives) rather than the warmup temp dir (which the trap deletes),
  # so even a warmup-iteration failure leaves a readable log.
  local xctrace_log="$OUTPUT_DIR/xctrace-${index}.log"
  # DE-CONFOUNDING (not causal): pass the perf env via xctrace `--env` flags
  # rather than as this shell's environment. `xctrace record --launch` starts
  # the app through LaunchServices, which does NOT reliably inherit the calling
  # shell's environment, so `--env` guarantees the launched app actually sees
  # `FEEDER_PERF_MODE`. This is a robustness fix, NOT the #132 root cause: the
  # direct-exec repro had the env set correctly and STILL idled — the missing
  # window activation was the cause (fixed in FeederApp's perf delegate). Env
  # flags stay BEFORE `--launch --`; everything after that token is argv for
  # the launched app, not xctrace flags.
  local status=0
  xcrun xctrace record \
    --template 'Time Profiler' \
    --time-limit "${TIME_LIMIT}ms" \
    --output "$out_file" \
    --env FEEDER_PERF_MODE=1 \
    --env FEEDER_PERF_DATASET_SIZE="$DATASET_SIZE" \
    --launch -- "$APP_BINARY" \
    >"$xctrace_log" 2>&1 || status=$?

  # xctrace's exit code is NOT a trustworthy pass/fail signal, so validate the
  # produced trace instead (issue #132). Lifting the check out from under
  # `set -e` (via `|| status=$?`) is what lets the tripwires below run at all —
  # they were dead code while a non-zero exit aborted the script first, which is
  # exactly why PR #133's OBJ-1 assertion was dormant.
  #
  # With the app-side activation fix the scenario self-exits `exit(0)` at the
  # end of the nav walk, so 0 is the EXPECTED path. Exit 54 is the observed
  # time-limit code — a bounded fallback, tolerated ONLY after a valid trace is
  # produced and the identity tripwires pass. Any OTHER non-zero code is a hard
  # failure. Only 0 and 54 are recognised; do NOT hard-code further codes.

  # (1) No trace bundle → the record failed to launch or capture. Fail loud
  # regardless of exit code. A host with no interactive WindowServer/GUI session
  # cannot render a window, so no trace is produced — surface that hint rather
  # than the misleading stale-binary text.
  if [[ ! -d "$out_file" ]]; then
    echo "ERROR: iteration $index produced NO trace bundle at '$out_file'" >&2
    echo "       (xctrace exit $status) — the record failed to launch/capture." >&2
    echo "       \`make perf\` requires a LOCAL interactive GUI session: the perf" >&2
    echo "       app must render a window (STACK §14 — perf is a local gate)." >&2
    echo "       Run it from a local login session and see '$xctrace_log'." >&2
    exit 1
  fi

  # (2) A trace exists but xctrace exited with an UNEXPECTED code (not 0, not
  # the 54 time-limit) → crash, bad signature, or launch failure. This PRESERVES
  # PR #133's fail-loud guard.
  if [[ "$status" -ne 0 && "$status" -ne 54 ]]; then
    echo "ERROR: iteration $index: xctrace exited $status (expected 0, or 54 for" >&2
    echo "       the time-limit). A trace was produced but this code signals a" >&2
    echo "       crash, bad signature, or launch failure — refusing to trust it." >&2
    echo "       See '$xctrace_log'." >&2
    exit 1
  fi

  # (4) Log a tolerated non-zero (54) exit per iteration so a run that hits the
  # time-limit on EVERY iteration stays visible — never laundered into green.
  if [[ "$status" -ne 0 ]]; then
    echo "==> iteration $index: xctrace exit $status tolerated (time-limit); validating trace"
  fi

  # (3) Identity tripwires run REGARDLESS of exit code: OBJ-1 (launch identity,
  # activates PR #133's dormant assertion) and OBJ-2 (no store-delete recovery).
  assert_perf_launch "$index" "$xctrace_log"
  # Symmetric post-iteration kill — even on success xctrace can leave
  # the launched FeederPerf running. Without this, the trap on EXIT would
  # only catch the last iteration's process, not the N-1 prior ones.
  kill_residual_feeder_processes
}

# Warm-up
run_iteration 0 "$WARMUP_DIR"

# Recorded iterations. xctrace .trace bundles are directories, not files,
# so `rm -f` silently skips them and the next run aborts ("is a directory").
# Use `rm -rf` to clear stale iteration bundles from prior runs.
rm -rf "$OUTPUT_DIR"/iteration-*.trace
for ((i=1; i<=ITERATIONS; i++)); do
  run_iteration "$i" "$OUTPUT_DIR"
done

echo "==> $ITERATIONS trace iterations captured in $OUTPUT_DIR"
