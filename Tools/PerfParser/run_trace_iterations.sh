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
#   NOTE: today this guard is DORMANT. The perf scenario does not run to
#   completion under a headless launch (follow-up #132), so xctrace time-limits
#   the still-running app and exits non-zero, and `set -e` aborts the script at
#   the record command BEFORE this check runs. It becomes the active gate once
#   #132 restores clean scenario completion (xctrace exits 0) and lands the
#   non-zero-exit handling. The check itself is correct and verified out of
#   band: the recorded xctrace log does contain `Launching process: FeederPerf`.
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
  FEEDER_PERF_MODE=1 \
  FEEDER_PERF_DATASET_SIZE="$DATASET_SIZE" \
    xcrun xctrace record \
      --template 'Time Profiler' \
      --time-limit "${TIME_LIMIT}ms" \
      --output "$out_file" \
      --launch -- "$APP_BINARY" \
      >"$xctrace_log" 2>&1
  # Validate the just-recorded trace: fail loud if xctrace launched the wrong/
  # stale binary (OBJ-1) or the perf build tripped store-delete recovery
  # (OBJ-2). Reached only when xctrace exits 0; under #132 the record command
  # exits non-zero and `set -e` aborts before here (see assert_perf_launch).
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
