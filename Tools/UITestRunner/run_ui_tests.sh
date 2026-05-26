#!/usr/bin/env bash
# Wraps `xcodebuild test-without-building -only-testing:FeederUITests` with
# pre/post cleanup of residual Feeder.app processes. Mirrors the trap shape
# proven in Tools/PerfParser/run_trace_iterations.sh — the UI-test runner
# has the same class of zombie-process bug: `xcodebuild` exits but the
# launched Feeder.app sometimes stays alive in the Dock. Across repeated
# `make test-ui` / `make test-full` runs that piles up.
set -euo pipefail

# Pattern matches the launched binary inside the bundle, not just any
# process named "Feeder". `--full` makes pkill match the whole `ps` line so
# we hit the binary path. This deliberately does NOT match the `xctest`
# runner process (different binary path) — only the launched app under test.
# `|| true` keeps the script alive when there is nothing to kill (the
# common case on first run).
FEEDER_BINARY_PATTERN="Feeder.app/Contents/MacOS/Feeder"

kill_residual_feeder_processes() {
  # Send TERM first so anything in-flight can flush cleanly. The brief
  # sleep is bounded so the cleanup does not stretch out the test run;
  # KILL follows for stragglers.
  pkill -TERM -f "$FEEDER_BINARY_PATTERN" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "$FEEDER_BINARY_PATTERN" 2>/dev/null || true
}

# `EXIT` fires on normal exit (pass or test failure); `INT TERM` cover
# user-interrupted runs (Ctrl-C) so the user does not have to hand-kill
# zombies after aborting a UI-test session. We deliberately do NOT use
# `exec xcodebuild` below — `exec` replaces the shell and the EXIT trap
# would never fire. Running xcodebuild as a child keeps the wrapper shell
# alive long enough for the trap to run post-xcodebuild.
trap kill_residual_feeder_processes EXIT INT TERM

# Belt-and-suspenders pre-kill: a prior aborted run (Ctrl-C between trap
# arming and exec, or a crash before the trap fired) can leave a Feeder
# instance running. Reap before launching a new one.
kill_residual_feeder_processes

# Forward all arguments to xcodebuild verbatim. The Makefile target owns
# the full argv (scheme, destination, result bundle, only-testing filter,
# signing settings) — this wrapper only adds the cleanup contract.
# `set -e` propagates xcodebuild's exit status; the EXIT trap still runs.
xcodebuild "$@"
