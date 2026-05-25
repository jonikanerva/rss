#!/usr/bin/env bash
# Perf-suite preflight check. Refuses to run when:
#   - thermal pressure is detected (CPU_Speed_Limit < 100)
# Logs (does not block) battery / uptime / CPU model for trace-result audit.
set -euo pipefail

echo "==> perf preflight"

THERM=$(pmset -g therm 2>/dev/null || true)
echo "$THERM"
SPEED_LIMIT=$(echo "$THERM" | awk '/CPU_Speed_Limit/ {print $NF; exit}')
if [[ -n "${SPEED_LIMIT:-}" && "${SPEED_LIMIT}" -lt 100 ]]; then
  echo "ERROR: thermal throttle detected — CPU_Speed_Limit=${SPEED_LIMIT}." >&2
  echo "       Let the system idle, then re-run \`make perf\`." >&2
  exit 1
fi

BATT=$(pmset -g batt 2>/dev/null | head -2 || true)
echo "$BATT"

UPTIME=$(uptime 2>/dev/null || true)
echo "uptime: $UPTIME"

CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
echo "cpu: $CPU_MODEL"

echo "==> preflight OK"
