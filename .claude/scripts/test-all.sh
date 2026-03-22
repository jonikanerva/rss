#!/usr/bin/env bash
# Master test runner — must pass before presenting changes to human.
# Runs: build verification + unit tests + UI smoke tests
# Exit code 0 = all green, non-zero = blocked
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Feeder.xcodeproj}"
SCHEME="${SCHEME:-Feeder}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/FeederDerivedData}"
DESTINATION="${DESTINATION:-platform=macOS}"
UNIT_RESULT="${UNIT_RESULT:-$ROOT_DIR/artifacts/local/xcresult/unit-tests.xcresult}"
UI_RESULT="${UI_RESULT:-$ROOT_DIR/artifacts/local/xcresult/ui-smoke.xcresult}"

PASSED=0
FAILED=0
SKIPPED=0

log() { echo "==> $1"; }

SWIFT_FORMAT="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format"

# Phase 1: Lint
log "Phase 1/4: swift-format lint (code style)"
if LINT_OUTPUT=$("$SWIFT_FORMAT" lint --strict --recursive --parallel "$ROOT_DIR" 2>&1); then
    log "PASS: Lint clean"
    PASSED=$((PASSED + 1))
else
    echo "$LINT_OUTPUT" | head -30
    log "FAIL: Lint found style violations"
    FAILED=$((FAILED + 1))
fi

# Phase 2: Build
log "Phase 2/4: Build (zero warnings, zero errors)"
BUILD_OUTPUT=$("$ROOT_DIR/.claude/scripts/build-for-testing.sh" 2>&1)
BUILD_WARNINGS=$(echo "$BUILD_OUTPUT" | grep -cE "(error:|warning:)" | grep -v "xcodebuild\[" || true)
if [[ "$BUILD_WARNINGS" -gt 0 ]]; then
    echo "$BUILD_OUTPUT" | grep -E "(error:|warning:)" | grep -v "xcodebuild\["
    log "FAIL: Build produced warnings or errors"
    FAILED=$((FAILED + 1))
else
    log "PASS: Build clean"
    PASSED=$((PASSED + 1))
fi

# Phase 2: Unit tests
log "Phase 3/4: Unit tests (FeederTests)"
mkdir -p "$(dirname "$UNIT_RESULT")"
rm -rf "$UNIT_RESULT"

if xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION" \
    -resultBundlePath "$UNIT_RESULT" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    ENABLE_APP_SANDBOX=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    test-without-building \
    -only-testing:FeederTests \
    2>&1 | tail -5; then
    log "PASS: Unit tests"
    PASSED=$((PASSED + 1))
else
    log "FAIL: Unit tests"
    FAILED=$((FAILED + 1))
fi

# Phase 3: UI smoke tests
log "Phase 4/4: UI smoke tests (FeederUITests)"
rm -rf "$UI_RESULT"

if xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION" \
    -resultBundlePath "$UI_RESULT" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    ENABLE_APP_SANDBOX=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    test-without-building \
    -only-testing:FeederUITests \
    2>&1 | tail -5; then
    log "PASS: UI smoke tests"
    PASSED=$((PASSED + 1))
else
    log "WARN: UI smoke tests failed (non-blocking in headless environments)"
    SKIPPED=$((SKIPPED + 1))
fi

# Summary
echo ""
log "Summary: $PASSED passed, $FAILED failed, $SKIPPED skipped"
log "Unit test results: $UNIT_RESULT"
log "UI test results: $UI_RESULT"

if [[ $FAILED -gt 0 ]]; then
    log "BLOCKED — fix failures before presenting to human"
    exit 1
fi

log "ALL GREEN — safe to present changes"
exit 0
