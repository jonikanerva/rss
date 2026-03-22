#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Feeder.xcodeproj}"
SCHEME="${SCHEME:-Feeder}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/FeederDerivedData}"

mkdir -p "$DERIVED_DATA_PATH"

echo "==> build-for-testing"
echo "project: $PROJECT_PATH"
echo "scheme: $SCHEME"
echo "configuration: $CONFIGURATION"
echo "derived data: $DERIVED_DATA_PATH"

# Ad-hoc signing (CODE_SIGN_IDENTITY=-) allows UI tests to launch the app
# without a full developer identity. Disable entitlements that require
# provisioning profiles since we don't have them in CI.
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_APP_SANDBOX=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  build-for-testing \
  "$@"
