#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Feeder.xcodeproj}"
SCHEME="${SCHEME:-Feeder}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/FeederDerivedData}"
DESTINATION="${DESTINATION:-platform=macOS}"
ONLY_TESTING="${ONLY_TESTING:-FeederUITests}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$ROOT_DIR/artifacts/local/xcresult/ui-smoke.xcresult}"
BUILD_FIRST="${BUILD_FIRST:-1}"

if [[ "$BUILD_FIRST" == "1" ]]; then
  "$ROOT_DIR/.claude/scripts/build-for-testing.sh"
fi

mkdir -p "$(dirname "$RESULT_BUNDLE_PATH")"
rm -rf "$RESULT_BUNDLE_PATH"

echo "==> ui smoke tests"
echo "result bundle: $RESULT_BUNDLE_PATH"
echo "destination: $DESTINATION"
echo "only-testing: $ONLY_TESTING"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "$DESTINATION" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_APP_SANDBOX=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  test-without-building \
  -only-testing:"$ONLY_TESTING" \
  "$@"

echo "==> done"
echo "xcresult: $RESULT_BUNDLE_PATH"
