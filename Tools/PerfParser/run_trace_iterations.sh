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

mkdir -p "$OUTPUT_DIR"
# Iteration 0 is warm-up — recorded but ignored by the parser by exclusion
# from the trace-dir naming convention.
WARMUP_DIR=$(mktemp -d)
trap "rm -rf '$WARMUP_DIR'" EXIT

run_iteration() {
  local index="$1"
  local out_dir="$2"
  local out_file="$out_dir/iteration-${index}.trace"
  rm -rf "$out_file"
  echo "==> trace iteration $index ($out_file)"
  FEEDER_PERF_MODE=1 \
  FEEDER_PERF_DATASET_SIZE="$DATASET_SIZE" \
    xcrun xctrace record \
      --template 'Time Profiler' \
      --launch -- "$APP_PATH" \
      --time-limit "${TIME_LIMIT}ms" \
      --output "$out_file" \
      >/dev/null
}

# Warm-up
run_iteration 0 "$WARMUP_DIR"

# Recorded iterations
rm -f "$OUTPUT_DIR"/iteration-*.trace
for ((i=1; i<=ITERATIONS; i++)); do
  run_iteration "$i" "$OUTPUT_DIR"
done

echo "==> $ITERATIONS trace iterations captured in $OUTPUT_DIR"
