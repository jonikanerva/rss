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
  FEEDER_PERF_MODE=1 \
  FEEDER_PERF_DATASET_SIZE="$DATASET_SIZE" \
    xcrun xctrace record \
      --template 'Time Profiler' \
      --time-limit "${TIME_LIMIT}ms" \
      --output "$out_file" \
      --launch -- "$APP_PATH" \
      >/dev/null
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
