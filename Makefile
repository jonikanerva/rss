# Feeder — Build, Test & Lint
# Usage: make <target>
#   make lint       — check code style
#   make lint-fix   — auto-fix code style
#   make build      — build for testing
#   make test       — unit tests (builds first)
#   make test-ui    — UI smoke tests (builds first)
#   make test-all   — quick gate: lint + build + unit (no UI)
#   make test-full  — full gate: lint + build + unit + UI
#   make clean      — remove derived data and artifacts

SHELL          := /bin/bash
.SHELLFLAGS    := -euo pipefail -c

PROJECT        ?= Feeder.xcodeproj
SCHEME         ?= Feeder
CONFIGURATION  ?= Debug
DERIVED_DATA   ?= /tmp/FeederDerivedData
DESTINATION    ?= platform=macOS
UNIT_RESULT    ?= artifacts/local/xcresult/unit-tests.xcresult
UI_RESULT      ?= artifacts/local/xcresult/ui-smoke.xcresult
REPORT_DIR     ?= artifacts/local/test-reports

XCODEBUILD_FLAGS = \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	-destination '$(DESTINATION)' \
	-allowProvisioningUpdates \
	ENABLE_APP_SANDBOX=NO \
	ENABLE_HARDENED_RUNTIME=NO

# NOTE: We deliberately let xcodebuild sign with the project's automatic
# `CODE_SIGN_STYLE = Automatic` + `DEVELOPMENT_TEAM` setting instead of passing
# `CODE_SIGNING_ALLOWED=NO`. macOS 26 tightened Gatekeeper so the XCTRunner
# bundle that `make test-ui` launches is killed by `syspolicyd` when it has no
# valid signature ("Gatekeeper policy blocked execution"). Leaving signing on
# lets the user's Apple Development identity validate the runner.

APP_NAME        ?= Feeder
INSTALL_DIR     ?= /Applications

# Perf-trace build identity. The perf/trace Release build renames its
# EXECUTABLE (PRODUCT_NAME=FeederPerf, see install-perf) and also ships under a
# distinct bundle id at a distinct app path. The EXECUTABLE rename is what makes
# `xctrace record --launch` resolve unambiguously: xctrace resolves its launch
# target by EXECUTABLE NAME through LaunchServices, and the daily app plus every
# Xcode Debug build all share the name `Feeder`, so a `Feeder`-named launch can
# hijack to the wrong (stale) build (issue #129). Nothing else ever sets
# PRODUCT_NAME=FeederPerf, so the perf executable name resolves to exactly this
# install even with Xcode open. The distinct bundle id + app path additionally
# keep perf runs from overwriting the user's daily `Feeder.app`; the shipping
# app identity (name, id, path) is untouched.
PERF_APP_NAME   ?= FeederPerf
PERF_BUNDLE_ID  ?= com.feeder.app.perf

.PHONY: lint lint-fix build install install-perf test test-stress-tsan c3-measure test-ui test-all test-full clean artifacts help \
        perf perf-signpost perf-trace perf-record-baseline perf-preflight

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------

lint: ## Check code style (swift-format --strict)
	@echo "==> swift-format lint"
	@xcrun swift-format lint --strict --recursive --parallel .

lint-fix: ## Auto-fix code style (swift-format)
	@echo "==> swift-format fix"
	@xcrun swift-format format --in-place --recursive --parallel .

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build: ## Build for testing (ad-hoc signing)
	@echo "==> build-for-testing"
	@mkdir -p $(DERIVED_DATA)
	xcodebuild build-for-testing $(XCODEBUILD_FLAGS)

install: ## Build Release and install to /Applications
	@echo "==> build Release"
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA) \
		-destination '$(DESTINATION)' \
		CODE_SIGN_IDENTITY="-" \
		ENABLE_APP_SANDBOX=NO \
		ENABLE_HARDENED_RUNTIME=NO
	@echo "==> install $(APP_NAME).app → $(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> done: $(INSTALL_DIR)/$(APP_NAME).app"

install-perf: ## Build Release under the perf bundle id + executable name and install as FeederPerf.app
	@echo "==> build Release (perf: id $(PERF_BUNDLE_ID), executable $(PERF_APP_NAME))"
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA) \
		-destination '$(DESTINATION)' \
		PRODUCT_BUNDLE_IDENTIFIER=$(PERF_BUNDLE_ID) \
		PRODUCT_NAME=$(PERF_APP_NAME) \
		PRODUCT_MODULE_NAME=$(APP_NAME) \
		CODE_SIGN_IDENTITY="-" \
		ENABLE_APP_SANDBOX=NO \
		ENABLE_HARDENED_RUNTIME=NO
	@echo "==> install $(PERF_APP_NAME).app → $(INSTALL_DIR)"
	@# PRODUCT_NAME=FeederPerf renames the built EXECUTABLE (not just the bundle
	@# id): the app-target Release product builds as FeederPerf.app with
	@# CFBundleExecutable `FeederPerf`, so `xctrace record --launch` — which
	@# resolves its target by executable name through LaunchServices — can no
	@# longer hijack the daily `Feeder` binary or an Xcode Debug build (#129).
	@# The build compiles only the app target, so this CLI override renames the
	@# app alone, never a test target.
	@#
	@# PRODUCT_MODULE_NAME is pinned back to Feeder so the Swift module — and the
	@# module-qualified SwiftData @Model identity (Feeder.Entry, …) — stays
	@# IDENTICAL to the shipping build, so perf measurements reflect production
	@# code. The perf app is SANDBOXED (the Feeder.entitlements app-sandbox key
	@# still applies despite ENABLE_APP_SANDBOX=NO), so its distinct bundle id
	@# gives it its OWN container store (~/Library/Containers/com.feeder.app.perf/
	@# …/Feeder.store) — fully ISOLATED from the daily app's store
	@# (~/Library/Containers/donut.Feeder/…). Perf runs cannot touch the user's
	@# real reading DB. The pin still earns its place: it keeps the perf
	@# container's @Model identity stable across runs and guards a future
	@# sandbox-off regression that would otherwise share a store.
	@rm -rf "$(INSTALL_DIR)/$(PERF_APP_NAME).app"
	@cp -R "$(DERIVED_DATA)/Build/Products/Release/$(PERF_APP_NAME).app" "$(INSTALL_DIR)/$(PERF_APP_NAME).app"
	@echo "==> done: $(INSTALL_DIR)/$(PERF_APP_NAME).app"

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

test: build ## Run unit tests (FeederTests, excluding the perf suite)
	@echo "==> unit tests"
	@mkdir -p $(dir $(UNIT_RESULT))
	@rm -rf $(UNIT_RESULT)
	@# `-parallel-testing-enabled NO` runs the whole target SERIALLY. The unit
	@# target has many suites that each spin up a fresh SwiftData `ModelContainer`
	@# (one Core Data coordinator apiece); Swift Testing runs suites in parallel by
	@# default, and `@Suite(.serialized)` only serialises WITHIN a suite — per
	@# Apple's docs it "does not influence how those tests run relative to unrelated
	@# tests", so it does NOT cap the number of coordinators alive at once across
	@# suites. Under that concurrency the coordinators intermittently abort the test
	@# host (a cascade of 0.000 s failures). Serialising the run caps it at one
	@# coordinator at a time — deterministic and green (STACK.md §14).
	xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-parallel-testing-enabled NO \
		-resultBundlePath $(UNIT_RESULT) \
		-only-testing:FeederTests \
		-skip-testing:FeederTests/PerfSignpostTests \
		-skip-testing:FeederTests/MicroBenchmarkTests \
		-skip-testing:FeederTests/C3ReadStarvationMeasurementTests

# Isolated Thread-Sanitizer run of the whole DataReader concurrency suite — the
# evidence gate for the shared-container topology (STACK.md §14). Its heavyweight
# member, `sharedContainerProductionShapeStress`, drives hundreds of concurrent
# read-during-write rounds on a shared on-disk container; run alongside the rest
# of the parallel test target's many coordinators it over-stresses Core Data and
# can abort (a test-parallelism artifact, not a product bug). It therefore
# self-skips (no-op) in the normal `make test-all` gate and runs only here:
#   make test-stress-tsan
#
# Three things this invocation gets right that a naive one does not:
#
# 1. Full `xcodebuild test` (build-for-testing + test), NOT `test-without-building`
#    — Thread Sanitizer is compile-time instrumentation, so it must be built into
#    the binary. Reusing the non-TSan `build` product and injecting
#    `-enableThreadSanitizer YES` only at run time launches the host under the
#    TSan runtime with an un-instrumented executable, which aborts at startup
#    ("crashed before establishing connection"). This target builds its own
#    TSan-instrumented product rather than depending on the plain `build` target.
#
# 2. `TEST_RUNNER_FEEDER_RUN_STRESS=1`, not a plain `FEEDER_RUN_STRESS=1` — a
#    plain variable set on the xcodebuild process does NOT reach the test-host
#    process, so the stress guard would never see it and would silently self-skip.
#    xcodebuild strips the `TEST_RUNNER_` prefix and sets `FEEDER_RUN_STRESS` in
#    the host's environment, which is where the guard reads it.
#
# 3. Suite-level `-only-testing:FeederTests/DataReaderConcurrencyTests`, not a
#    per-test selector — a Swift Testing single-test selector
#    (`.../sharedContainerProductionShapeStress`) enters the suite but matches
#    zero cases, so nothing runs. Running only this `.serialized` suite gives the
#    required isolation: it is the sole suite in the process, and `.serialized`
#    runs each of its tests (the stress test included) one at a time.
test-stress-tsan: ## Isolated Thread-Sanitizer run of the DataReader concurrency suite
	@mkdir -p $(DERIVED_DATA)
	TEST_RUNNER_FEEDER_RUN_STRESS=1 xcodebuild test \
		$(XCODEBUILD_FLAGS) \
		-parallel-testing-enabled NO \
		-enableThreadSanitizer YES \
		-only-testing:FeederTests/DataReaderConcurrencyTests

# C3 read-starvation measurement (issue #138 PR A). HEAVY (tens of minutes at
# locked params) — skipped in `make test-all`, run explicitly here. No Thread
# Sanitizer (it dilates timings and would corrupt the latency measurement).
# `TEST_RUNNER_FEEDER_C3_MEASURE=1` reaches the test-host process (xcodebuild
# strips the `TEST_RUNNER_` prefix) so the suite's `.enabled(if:)` fires; a
# plain env var would not (same idiom as `test-stress-tsan`). Set
# `C3_SMOKE=1 make c3-measure` for a fast harness self-check (NOT a verdict).
c3-measure: build ## C3 read-starvation measurement + disposition verdict (#138 PR A)
	@mkdir -p $(DERIVED_DATA)
	@# Quiet the app test host: an EMPTY in-memory store + forced onboarding so
	@# FeederApp does NOT boot the real reading DB, start a periodic sync, or run
	@# the extracted-content network/WebKit fetch — that app activity collides
	@# with the long, heavy measurement and crashes the host. The measurement's
	@# own on-disk WAL containers are separate and unaffected.
	TEST_RUNNER_FEEDER_C3_MEASURE=1 \
	TEST_RUNNER_FEEDER_C3_SMOKE=$(if $(C3_SMOKE),1,0) \
	TEST_RUNNER_FEEDER_C3_MEDIUM=$(if $(C3_MEDIUM),1,0) \
	TEST_RUNNER_UITEST_IN_MEMORY_STORE=1 \
	TEST_RUNNER_UITEST_FORCE_ONBOARDING=1 \
		xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-parallel-testing-enabled NO \
		-only-testing:FeederTests/C3ReadStarvationMeasurementTests

test-ui: build ## Run UI smoke tests (FeederUITests)
	@echo "==> UI smoke tests"
	@mkdir -p $(dir $(UI_RESULT))
	@rm -rf $(UI_RESULT)
	@# Invoked via the UI-test runner wrapper so residual Feeder.app
	@# processes are reaped before and after the run (same class of
	@# zombie-process bug fixed for `make perf` in Tools/PerfParser/run_trace_iterations.sh).
	@# `test-full` composes `test test-ui` so it inherits the cleanup automatically.
	./Tools/UITestRunner/run_ui_tests.sh test-without-building \
		$(XCODEBUILD_FLAGS) \
		-resultBundlePath $(UI_RESULT) \
		-only-testing:FeederUITests

# ---------------------------------------------------------------------------
# Full gate
# ---------------------------------------------------------------------------

test-all: lint build test ## Quick gate: lint + build + unit (no UI)

test-full: lint build test test-ui ## Full gate: lint + build + unit + UI

# ---------------------------------------------------------------------------
# Artifacts
# ---------------------------------------------------------------------------

artifacts: ## Extract test results summary from xcresult bundles
	@mkdir -p $(REPORT_DIR)
	@echo "==> extracting test results summary"
	xcrun xcresulttool get test-results summary \
		--path $(UI_RESULT) \
		--compact > $(REPORT_DIR)/ui-smoke-summary.json
	@echo "==> done: $(REPORT_DIR)/ui-smoke-summary.json"

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

clean: ## Remove derived data and test artifacts
	@echo "==> clean"
	rm -rf $(DERIVED_DATA)
	rm -rf artifacts/local
	@echo "==> done"

# ---------------------------------------------------------------------------
# Perf (local-only headless suite — not chained into test-all)
# ---------------------------------------------------------------------------

PERF_RESULT_DIR  ?= artifacts/local/perf
PERF_BASELINE    ?= Tests/PerfBaselines/baseline-current.json
PERF_DATASET     ?= 5000
PERF_ITERATIONS  ?= 5
# Recording ceiling per iteration. The full deterministic scenario — fresh
# 5000-row seed (~6 s) + nav walk (~12 s) + trailing flush — self-exits at
# ~19-22 s, so the app terminates well before this ceiling and xctrace returns
# 0. 20 s left almost no margin (the nav window alone ends ~18.5 s), so a
# thermally-loaded iteration raced the limit and got killed before the
# `perf-nav-window` closed. 40 s is headroom, not a target (issue #132).
PERF_TIME_LIMIT  ?= 40000

perf: perf-preflight perf-signpost perf-trace ## Local perf regression suite (Levels 2 + 4)
	@echo "==> perf: PASS"

perf-preflight: ## Verify the host is not thermally throttled before recording
	@./Tools/PerfParser/preflight.sh

perf-signpost: build ## Levels 1 + 2 — function-level XCTest microbenchmarks + XCTOSSignpostMetric medians
	@mkdir -p $(PERF_RESULT_DIR)
	@rm -rf $(PERF_RESULT_DIR)/signpost.xcresult
	xcodebuild test-without-building $(XCODEBUILD_FLAGS) \
		-resultBundlePath $(PERF_RESULT_DIR)/signpost.xcresult \
		-only-testing:FeederTests/PerfSignpostTests \
		-only-testing:FeederTests/MicroBenchmarkTests
	@swift run --package-path Tools/PerfParser PerfParser \
		--xcresult $(PERF_RESULT_DIR)/signpost.xcresult \
		--baseline $(PERF_BASELINE)

perf-trace: install-perf ## Level 4 — xctrace Time Profiler, median over N iterations
	@./Tools/PerfParser/run_trace_iterations.sh \
		--iterations $(PERF_ITERATIONS) \
		--time-limit $(PERF_TIME_LIMIT) \
		--output-dir $(PERF_RESULT_DIR) \
		--dataset-size $(PERF_DATASET) \
		--app-path "$(INSTALL_DIR)/$(PERF_APP_NAME).app"
	@swift run --package-path Tools/PerfParser PerfParser \
		--trace-dir $(PERF_RESULT_DIR) \
		--baseline $(PERF_BASELINE)

perf-record-baseline: perf-preflight install-perf ## Refresh baseline JSON from current run
	@echo "==> perf-record-baseline (refreshes baseline from this run)"
	@./Tools/PerfParser/run_trace_iterations.sh \
		--iterations $(PERF_ITERATIONS) \
		--time-limit $(PERF_TIME_LIMIT) \
		--output-dir $(PERF_RESULT_DIR) \
		--dataset-size $(PERF_DATASET) \
		--app-path "$(INSTALL_DIR)/$(PERF_APP_NAME).app"
	@swift run --package-path Tools/PerfParser PerfParser \
		--trace-dir $(PERF_RESULT_DIR) \
		--baseline $(PERF_BASELINE) \
		--write-baseline
	@mkdir -p $(PERF_RESULT_DIR)
	@rm -rf $(PERF_RESULT_DIR)/signpost.xcresult
	xcodebuild test-without-building $(XCODEBUILD_FLAGS) \
		-resultBundlePath $(PERF_RESULT_DIR)/signpost.xcresult \
		-only-testing:FeederTests/PerfSignpostTests \
		-only-testing:FeederTests/MicroBenchmarkTests
	@swift run --package-path Tools/PerfParser PerfParser \
		--xcresult $(PERF_RESULT_DIR)/signpost.xcresult \
		--baseline $(PERF_BASELINE) \
		--write-baseline
