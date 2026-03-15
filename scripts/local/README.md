# Local Build + UI Smoke Scripts

These scripts run Feeder build and local UI smoke tests without external CI.

## Commands

```bash
# 1) Build once for test execution
scripts/local/build-for-testing.sh

# 2) Run UI smoke suite (uses test-without-building)
scripts/local/ui-smoke.sh

# 3) Extract result summary JSON from xcresult
scripts/local/collect-test-artifacts.sh
```

## Environment overrides

- `DERIVED_DATA_PATH` (default: `/tmp/FeederDerivedData`)
- `RESULT_BUNDLE_PATH` (default: `artifacts/local/xcresult/ui-smoke.xcresult`)
- `ONLY_TESTING` (default: `FeederUITests`)
- `DESTINATION` (default: `platform=macOS`)

