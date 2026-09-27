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

# /usr/bin/make is GNU Make 3.81, which ignores .SHELLFLAGS: start each recipe
# line that has a pipeline or a command substitution with `set -euo pipefail;`.
SHELL          := /bin/bash
.SHELLFLAGS    := -euo pipefail -c

PROJECT        ?= Feeder.xcodeproj
SCHEME         ?= Feeder
CONFIGURATION  ?= Debug
# A full clone builds in /tmp/FeederDerivedData, so a second full clone shares
# that folder. A linked worktree, or a copy without .git, builds in its own
# .build/DerivedData (STACK.md § 3 → Build folders). A linked worktree is also
# its own top level, so only its git dir tells it apart from a full clone.
ifeq ($(shell git rev-parse --show-toplevel 2>/dev/null),$(CURDIR))
ifneq ($(filter %/.git,$(shell git rev-parse --absolute-git-dir 2>/dev/null)),)
DERIVED_DATA   ?= /tmp/FeederDerivedData
endif
endif
DERIVED_DATA   ?= $(CURDIR)/.build/DerivedData
DESTINATION    ?= platform=macOS
UNIT_RESULT    ?= artifacts/local/xcresult/unit-tests.xcresult
UI_RESULT      ?= artifacts/local/xcresult/ui-smoke.xcresult
# Test selectors, separated by spaces. Select a Swift Testing suite as a whole
# (FeederTests/<Suite>, the type name): a single-test selector can match no test.
UNIT_TEST      ?= FeederTests
UI_TEST        ?= FeederUITests
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

.PHONY: lint lint-fix build install test test-stress-tsan test-ui test-focus test-all test-full clean artifacts help

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

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

# $(call xcresult_field,<result bundle>,<key>) prints one top-level field of the
# bundle's test summary.
xcresult_field = xcrun xcresulttool get test-results summary --path '$(1)' --compact | plutil -extract $(2) raw -o - -

# $(call only_testing,<selectors>) gives each selector its own -only-testing
# argument. An empty list stops make: without an -only-testing argument,
# xcodebuild runs every test target of the scheme, UI tests included.
only_testing = $(addprefix -only-testing:,$(or $(strip $(1)),$(error The test selector list is empty; name at least one suite or method)))

# $(call require_passed_tests,<result bundle>,<selectors>) fails the run when
# fewer tests passed than there are selectors. The guard counts passed tests, so
# it proves that a selector matched a test only when the run has one selector,
# or when each selector names one test method.
require_passed_tests = set -euo pipefail; \
	passed=$$($(call xcresult_field,$(1),passedTests)); \
	[ "$$passed" -ge $(words $(2)) ] || \
	{ echo "error: $$passed tests passed, fewer than the number of selectors ($(words $(2))): $(strip $(2))" >&2; exit 1; }

test: build ## Run unit tests; UNIT_TEST=FeederTests/<Suite> runs one suite
	@echo "==> unit tests"
	@mkdir -p $(dir $(UNIT_RESULT))
	@rm -rf $(UNIT_RESULT)
	@# Keep the run serial: many SwiftData coordinators alive at once can abort
	@# the test host, and `@Suite(.serialized)` orders tests only inside one suite
	@# (STACK.md § 14).
	@# Keep the `TEST_RUNNER_` prefix: xcodebuild passes only prefixed variables
	@# to the test host. xcodebuild strips the prefix: the host reads
	@# `FEEDER_HEADLESS`. The headless host uses an in-memory store, reads no
	@# Keychain item, and starts no sync, so no consent prompt stops the run.
	TEST_RUNNER_FEEDER_HEADLESS=1 xcodebuild test-without-building \
		$(XCODEBUILD_FLAGS) \
		-parallel-testing-enabled NO \
		-resultBundlePath $(UNIT_RESULT) \
		$(call only_testing,$(UNIT_TEST))
	@$(call require_passed_tests,$(UNIT_RESULT),$(UNIT_TEST))

# Thread Sanitizer run of the DataReader concurrency suite, the evidence for the
# shared-container topology (STACK.md § 14). The suite's stress test runs only
# here; the unit run skips it.
test-stress-tsan: ## Isolated Thread-Sanitizer run of the DataReader concurrency suite
	@mkdir -p $(DERIVED_DATA)
	@# Keep `xcodebuild test`: Thread Sanitizer is compiled in, so this target
	@# builds its own instrumented product and must not reuse `build`.
	@# Keep the `TEST_RUNNER_` prefix: only prefixed variables reach the test
	@# host. The headless host stays out of the Keychain and the app's store.
	@# Keep the suite selector: a single-test selector can match no test. As the
	@# only suite in the process, the `.serialized` suite runs one test at a time.
	TEST_RUNNER_FEEDER_HEADLESS=1 TEST_RUNNER_FEEDER_RUN_STRESS=1 xcodebuild test \
		$(XCODEBUILD_FLAGS) \
		-parallel-testing-enabled NO \
		-enableThreadSanitizer YES \
		-only-testing:FeederTests/DataReaderConcurrencyTests

test-ui: build ## Run UI tests; UI_TEST selects one or more suites or methods
	@echo "==> UI smoke tests"
	@mkdir -p $(dir $(UI_RESULT))
	@rm -rf $(UI_RESULT)
	FEEDER_UI_PRODUCTS_DIR="$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)" \
		./Tools/UITestRunner/run_ui_tests.sh test-without-building \
		$(XCODEBUILD_FLAGS) \
		-resultBundlePath $(UI_RESULT) \
		$(call only_testing,$(UI_TEST))
	@$(call require_passed_tests,$(UI_RESULT),$(UI_TEST))

# The owner-run focus check (STACK.md § 3 → Gates).
test-focus: UI_TEST = FeederUITests/FeederUITests/testClickReclaimsFocusFromWebViewForSidebarArrows \
	FeederUITests/FeederUITests/testClickArticleRowThenArrowSelectsNextRow \
	FeederUITests/FeederUITests/testBareKeyRInsideWebViewTogglesViewMode
test-focus: UI_RESULT = artifacts/local/xcresult/ui-focus.xcresult
test-focus: test-ui ## Owner-run focus check: the three focus UI tests in one launch

# ---------------------------------------------------------------------------
# Full gate
# ---------------------------------------------------------------------------

# test-all is gate evidence (STACK.md § 3 → Gates), so it runs every unit test.
# RUN_START must stay `:=`, so make records HEAD and the tree state at parse
# time, before any recipe runs. Only this recipe prints the stamp; a sub-make
# would record its own start.
ifneq ($(filter test-all,$(MAKECMDGOALS)),)
ifneq ($(strip $(UNIT_TEST)),FeederTests)
$(error make test-all runs every unit test and refuses UNIT_TEST="$(UNIT_TEST)"; use make test for a selection)
endif
RUN_START      := $(shell git rev-parse --verify -q HEAD 2>/dev/null)$(if $(shell git --no-optional-locks status --porcelain --untracked-files=normal 2>/dev/null || echo error),+dirty)
endif

test-all: lint build test ## Quick gate: lint + build + unit (no UI), then the verify: line
	@set -euo pipefail; \
	start='$(RUN_START)'; \
	head=$$(git rev-parse --verify -q HEAD 2>/dev/null || true); \
	changes=$$(git --no-optional-locks status --porcelain --untracked-files=normal 2>/dev/null || echo error); \
	if [ -z "$${start%+dirty}" ] || [ -z "$$head" ]; then \
		echo "error: the verify stamp needs a git HEAD" >&2; exit 1; \
	fi; \
	tree=dirty; \
	if [ "$$start" = "$$head" ] && [ -z "$$changes" ]; then tree=clean; fi; \
	result=$$($(call xcresult_field,$(UNIT_RESULT),result)); \
	tests=$$($(call xcresult_field,$(UNIT_RESULT),passedTests)); \
	echo "verify: head=$$head tree=$$tree result=$$result tests=$$tests"

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
