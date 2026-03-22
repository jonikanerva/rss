#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULT_BUNDLE_PATH="${1:-$ROOT_DIR/artifacts/local/xcresult/ui-smoke.xcresult}"
REPORT_DIR="${2:-$ROOT_DIR/artifacts/local/test-reports}"
REPORT_PATH="$REPORT_DIR/ui-smoke-summary.json"

if [[ ! -d "$RESULT_BUNDLE_PATH" ]]; then
  echo "Missing xcresult bundle: $RESULT_BUNDLE_PATH" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"

echo "==> extracting test results summary"
echo "source: $RESULT_BUNDLE_PATH"
echo "output: $REPORT_PATH"

xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE_PATH" \
  --compact > "$REPORT_PATH"

echo "==> done"
