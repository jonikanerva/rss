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

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing \
  "$@"
