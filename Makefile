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
# Full gate
# ---------------------------------------------------------------------------

test-all: lint build test test-ui ## Full test gate: lint + build + unit + UI

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
