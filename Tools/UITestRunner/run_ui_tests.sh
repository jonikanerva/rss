#!/usr/bin/env bash
set -euo pipefail

: "${FEEDER_UI_PRODUCTS_DIR:?The Makefile must provide the UI test products directory.}"
TEST_APP_BINARY="$FEEDER_UI_PRODUCTS_DIR/Feeder.app/Contents/MacOS/Feeder"
TEST_RUNNER_BINARY="$FEEDER_UI_PRODUCTS_DIR/FeederUITests-Runner.app/Contents/MacOS/FeederUITests-Runner"
runner_pid=""

find_test_pids() {
  ps -axo pid=,comm= | awk -v app="$TEST_APP_BINARY" -v runner="$TEST_RUNNER_BINARY" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if ($0 == app || $0 == runner) print pid
    }'
}

cleanup_test_apps() {
  local pids
  pids=$(find_test_pids)
  [[ -n "$pids" ]] || return 0
  kill -TERM $pids 2>/dev/null || true
  for _ in {1..10}; do
    pids=$(find_test_pids)
    [[ -n "$pids" ]] || return 0
    sleep 0.1
  done
  pids=$(find_test_pids)
  [[ -z "$pids" ]] || kill -KILL $pids 2>/dev/null || true
}

stop_run() {
  local status="$1"
  trap - INT TERM
  if [[ -n "$runner_pid" ]]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
  fi
  cleanup_test_apps
  if [[ -n "$runner_pid" ]]; then
    kill -KILL "$runner_pid" 2>/dev/null || true
  fi
  exit "$status"
}

trap cleanup_test_apps EXIT
trap 'stop_run 130' INT
trap 'stop_run 143' TERM

cleanup_test_apps
xcodebuild "$@" &
runner_pid=$!
status=0
wait "$runner_pid" || status=$?
runner_pid=""
exit "$status"
