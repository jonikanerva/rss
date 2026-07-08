#!/usr/bin/env bash
# Launches the Release Feeder.app under FEEDER_PERF_MODE=1 inside
# `xctrace record` for N iterations, dropping the first as warm-up. The
# parser then takes per-metric medians across the remaining iterations.
set -euo pipefail

ITERATIONS=5
TIME_LIMIT=20000
OUTPUT_DIR="artifacts/local/perf"
DATASET_SIZE=5000
APP_PATH="/Applications/Feeder.app"

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
  echo "ERROR: $APP_PATH not found. Run \`make install\` first." >&2
  exit 1
fi

# Resolve the concrete Mach-O to launch. `xctrace record --launch` normalises
# an executable path back to its enclosing `.app` and resolves the bundle id
# through LaunchServices, so the launched binary is whatever LaunchServices
# considers canonical for that id — NOT necessarily the path passed here. The
# perf build sidesteps that by shipping under a DISTINCT bundle id
# (`com.feeder.app.perf`, via `make install-perf`) with no competing
# registration, so resolution is unambiguous even when the shipping
# `com.feeder.app` is registered by an open Xcode session.
#
# The perf bundle is installed as `FeederPerf.app` but its executable keeps the
# built name (`Feeder`), so derive the binary from `CFBundleExecutable` rather
# than assuming it matches the bundle name.
APP_EXECUTABLE="$(defaults read "$APP_PATH/Contents/Info" CFBundleExecutable 2>/dev/null || basename "$APP_PATH" .app)"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
if [[ ! -x "$APP_BINARY" ]]; then
  echo "ERROR: $APP_BINARY not found or not executable. Run \`make install-perf\` first." >&2
  exit 1
fi

# Pattern matching the launched binary inside the bundle.
# `xctrace record --launch` does not always reap the launched Feeder
# process when the recording's time-limit elapses — the trace closes but
# Feeder keeps running in the Dock. Across N iterations that piles up.
# `--full` matches the whole `ps` line so we hit the binary path, not
# just any process named "Feeder". `|| true` keeps the script alive when
# there is nothing to kill (the common case on first run).
FEEDER_BINARY_PATTERN="Feeder.app/Contents/MacOS/Feeder"

kill_residual_feeder_processes() {
  # Send TERM first so anything in-flight can flush cleanly. The brief
  # sleep is bounded so the loop does not stretch out perf runs; KILL
  # follows for stragglers.
  pkill -TERM -f "$FEEDER_BINARY_PATTERN" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "$FEEDER_BINARY_PATTERN" 2>/dev/null || true
}

# Register the perf bundle with LaunchServices so `xctrace --launch` resolves
# its distinct id (`com.feeder.app.perf`) to this exact install. Because that
# id has no competing registration (Xcode only ever builds the shipping
# `com.feeder.app`), this resolves unambiguously even with Xcode open. The
# perf parser still fails closed with a clear message if the `perf-nav-window`
# interval is ever absent, so a mis-launch can never pass silently.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_PATH" || true
fi

mkdir -p "$OUTPUT_DIR"
# Iteration 0 is warm-up — recorded but ignored by the parser by exclusion
# from the trace-dir naming convention.
WARMUP_DIR=$(mktemp -d)
# Cleanup trap covers the warmup tmpdir AND any residual Feeder process
# the user may have left mid-run (Ctrl-C, OOM, or a `xctrace` crash).
# `EXIT` fires on normal exit; `INT TERM` cover user-interrupted runs so
# the boss does not have to hand-kill zombies after a Ctrl-C.
trap "kill_residual_feeder_processes; rm -rf '$WARMUP_DIR'" EXIT INT TERM

run_iteration() {
  local index="$1"
  local out_dir="$2"
  local out_file="$out_dir/iteration-${index}.trace"
  rm -rf "$out_file"
  # Belt-and-suspenders: kill any Feeder process left over from the
  # previous iteration before launching the next one. The trace bundle's
  # `--time-limit` does not always reap the launched process, so without
  # this each iteration would stack another Feeder in the Dock.
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
  # Symmetric post-iteration kill — even on success xctrace can leave
  # the launched Feeder running. Without this, the trap on EXIT would
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
