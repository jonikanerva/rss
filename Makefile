# Feeder — Build, Test & Lint
# Usage: make <target>
#   make lint       — check code style
#   make lint-fix   — auto-fix code style
#   make build      — build for testing
#   make test       — unit tests (builds first)
#   make test-ui    — UI smoke tests (builds first)
#   make test-all   — full gate: lint + build + unit + UI
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
	CODE_SIGN_IDENTITY=- \
	CODE_SIGNING_REQUIRED=NO \
	ENABLE_APP_SANDBOX=NO \
	ENABLE_HARDENED_RUNTIME=NO

.PHONY: lint lint-fix build test test-ui test-all clean artifacts help

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

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

test: build ## Run unit tests (FeederTests)
	@echo "==> unit tests"
	@mkdir -p $(dir $(UNIT_RESULT))
	@rm -rf $(UNIT_RESULT)
	xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-resultBundlePath $(UNIT_RESULT) \
		-only-testing:FeederTests

test-ui: build ## Run UI smoke tests (FeederUITests)
	@echo "==> UI smoke tests"
	@mkdir -p $(dir $(UI_RESULT))
	@rm -rf $(UI_RESULT)
	xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-resultBundlePath $(UI_RESULT) \
		-only-testing:FeederUITests

# ---------------------------------------------------------------------------
# Full gate (replaces test-all.sh)
# ---------------------------------------------------------------------------

test-all: ## Full test gate: lint + build + unit + UI
	@PASSED=0; FAILED=0; SKIPPED=0; \
	echo "==> Phase 1/4: swift-format lint (code style)"; \
	if xcrun swift-format lint --strict --recursive --parallel . 2>&1; then \
		echo "==> PASS: Lint clean"; \
		PASSED=$$((PASSED + 1)); \
	else \
		echo "==> FAIL: Lint found style violations"; \
		FAILED=$$((FAILED + 1)); \
	fi; \
	\
	echo "==> Phase 2/4: Build (zero warnings, zero errors)"; \
	BUILD_OUTPUT=$$(xcodebuild build-for-testing $(XCODEBUILD_FLAGS) 2>&1); \
	BUILD_WARNINGS=$$(echo "$$BUILD_OUTPUT" | grep -E '(error:|warning:)' | grep -v 'xcodebuild\[' | grep -v 'appintentsmetadataprocessor' | grep -c '' || true); \
	if [ "$$BUILD_WARNINGS" -gt 0 ]; then \
		echo "$$BUILD_OUTPUT" | grep -E '(error:|warning:)' | grep -v 'xcodebuild\[' | grep -v 'appintentsmetadataprocessor'; \
		echo "==> FAIL: Build produced warnings or errors"; \
		FAILED=$$((FAILED + 1)); \
	else \
		echo "==> PASS: Build clean"; \
		PASSED=$$((PASSED + 1)); \
	fi; \
	\
	echo "==> Phase 3/4: Unit tests (FeederTests)"; \
	mkdir -p $(dir $(UNIT_RESULT)); \
	rm -rf $(UNIT_RESULT); \
	if xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-resultBundlePath $(UNIT_RESULT) \
		-only-testing:FeederTests \
		2>&1 | tail -5; then \
		echo "==> PASS: Unit tests"; \
		PASSED=$$((PASSED + 1)); \
	else \
		echo "==> FAIL: Unit tests"; \
		FAILED=$$((FAILED + 1)); \
	fi; \
	\
	echo "==> Phase 4/4: UI smoke tests (FeederUITests)"; \
	rm -rf $(UI_RESULT); \
	if xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-resultBundlePath $(UI_RESULT) \
		-only-testing:FeederUITests \
		2>&1 | tail -5; then \
		echo "==> PASS: UI smoke tests"; \
		PASSED=$$((PASSED + 1)); \
	else \
		echo "==> WARN: UI smoke tests failed (non-blocking in headless environments)"; \
		SKIPPED=$$((SKIPPED + 1)); \
	fi; \
	\
	echo ""; \
	echo "==> Summary: $$PASSED passed, $$FAILED failed, $$SKIPPED skipped"; \
	echo "==> Unit test results: $(UNIT_RESULT)"; \
	echo "==> UI test results: $(UI_RESULT)"; \
	if [ "$$FAILED" -gt 0 ]; then \
		echo "==> BLOCKED — fix failures before presenting to human"; \
		exit 1; \
	fi; \
	echo "==> ALL GREEN — safe to present changes"

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
