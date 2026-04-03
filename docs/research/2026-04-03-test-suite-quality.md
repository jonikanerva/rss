# Research: Test Suite Quality Review

Date: 2026-04-03
Status: Complete

## 1. Problem

The Feeder test suite has three categories of issues:

**Operational friction:**
- UI automation tests (XCUITest) take over the entire screen — any mouse/keyboard input from the developer fails the running test.
- Keychain password prompt appears on every test run despite "Always Allow" being selected.

**Coverage & value questions:**
- Are the current ~110 unit tests + 5 UI tests covering meaningful scenarios?
- Is anything overtested (friction without value) or undertested (gaps)?

**Infrastructure:**
- The Makefile's `test-all` target runs lint → build → unit → UI as a serial gate. UI tests blocking the developer's machine makes this impractical for routine use.

## 2. Constraints

| Constraint | Detail |
|---|---|
| macOS-only app | No iOS simulator — XCUITests run on the host machine directly |
| Swift 6 strict concurrency | Tests must compile with `SWIFT_STRICT_CONCURRENCY=complete` |
| SwiftData + ModelActor | DataWriter is an actor; tests need in-memory ModelContainers |
| Apple Foundation Models | Classification depends on on-device LLM — not testable in unit tests |
| Xcode project (not SPM) | Tests run via `xcodebuild`, not `swift test` |
| No CI server | All tests run on the developer's machine |

## 3. Current Test Suite Assessment

### Unit Tests (FeederTests.swift — ~90 tests, Swift Testing)

**High-value tests (keep):**
- `DeepestMatchTests` (7 tests) — tests the core classification post-processing logic with edge cases
- `ConfidenceGateTests` (10 tests) — tests the LLM confidence gating and keyword override logic
- `KeywordMatchConfidenceTests` (7 tests) — tests keyword scoring for classification fallback
- `FilterValidLabelsTests` (5 tests) — tests label validation against known category set
- `InputValidationGateTests` (5 tests) — tests skip-classification logic
- `ClassificationInstructionsTests` (6 tests) — tests prompt generation for LLM
- `HTMLStrippingTests` (9 tests) — tests HTML→plaintext for article content parsing
- `StoryKeyTests` (8 tests) — tests story grouping key normalization
- `ArticleBlockTests` (7 tests) — tests content block serialization/deserialization
- `FeedbinHelperTests` (8 tests) — tests API helper functions (link parsing, date formatting, HTTP status mapping)

**Low-value tests (candidates for removal or rethinking):**
- `CategoryModelTests` (5 tests) — tests SwiftData model init defaults (parentLabel, depth, isTopLevel, isSystem). These test the model's stored properties, which is effectively testing SwiftData/Swift itself.
- `CategoryDefinitionTests` (2 tests) — tests DTO struct field assignment. Pure struct construction — no logic to test.
- `ArticleKeepDaysTests` (2 tests) — one tests `UserDefaults.standard.integer()` returning 0 for a nonexistent key (testing Foundation), the other tests arithmetic (`3 * 86400 == 259200`).
- `DateFormattingTests` (7 tests) — partially valuable (Today/Yesterday prefix logic is custom), but ordinal suffix tests (1st, 2nd, 3rd, 11th, 21st) are testing a pure formatting function that's unlikely to break.
- `LanguageDetectionTests` (2 tests) — tests Apple's `NLLanguageRecognizer` wrapper. The wrapper is a one-liner; these test Apple's framework.

### DataWriter Integration Tests (DataWriterCategoryTests.swift — 18 tests, Swift Testing)

**All high-value.** These test actual SwiftData operations through the `DataWriter` actor:
- Category CRUD (add, delete with cascade, update fields, sort orders)
- Hierarchy management (promote/demote, orphan handling)
- System category protection (uncategorized cannot be deleted or reparented)
- Seed defaults

These use `ModelConfiguration(isStoredInMemoryOnly: true)` correctly and test real business logic.

### UI Tests (FeederUITests.swift — 4 tests, XCTest)

| Test | Value | Issue |
|---|---|---|
| `testOnboardingFormEnablesConnectButton` | Medium — tests form validation | Takes over screen |
| `testDemoTimelineInteractionSmoke` | High — tests core navigation flow | Takes over screen |
| `testArticleFilterSwitchesAndPreservesEntry` | High — tests filter tab switching | Takes over screen |
| `testLaunchPerformance` | Low — `XCTApplicationLaunchMetric` measures cold launch time but has no meaningful threshold/assertion | Takes over screen, noisy |

### Launch Tests (FeederUITestsLaunchTests.swift — 1 test)

- `testLaunch` with `runsForEachTargetApplicationUIConfiguration: true` — takes a screenshot on every UI configuration. **Low value**: captures a screenshot but doesn't assert anything. Also runs against the REAL app (no demo mode flags set), which means it hits the real Keychain and triggers the password prompt.

## 4. Alternatives

### A: Minimal fix — fix Keychain + separate UI test workflow

**Changes:**
1. Add `CODE_SIGNING_ALLOWED=NO` to Makefile XCODEBUILD_FLAGS for test targets (eliminates Keychain prompts completely since ad-hoc signing is what triggers them)
2. Split `test-all` into `test-all` (lint + build + unit only) and `test-full` (includes UI)
3. Remove `FeederUITestsLaunchTests.swift` (takes screenshot against real app, triggers Keychain, no assertions)
4. Remove `testLaunchPerformance` (no threshold, noisy)

**Pros:** Fastest to implement, immediately unblocks daily workflow.
**Cons:** UI tests still take over screen when run; doesn't address test quality.

### B: Full cleanup — fix infra + prune low-value tests + improve coverage

Everything from A, plus:
1. Remove low-value unit tests (CategoryModelTests, CategoryDefinitionTests, ArticleKeepDaysTests)
2. Trim DateFormattingTests to just Today/Yesterday tests (remove ordinal suffix tests)
3. Trim LanguageDetectionTests (wrapper too thin to test meaningfully)
4. Add missing DataWriter tests for entry operations (`persistEntries`, `applyClassification`, `markAsRead`)
5. Add FeedbinClient response parsing tests (mock JSON → DTO mapping)

**Pros:** Cleaner suite, better signal-to-noise ratio, fills real coverage gaps.
**Cons:** More work, some removal is subjective.

### C: Architectural shift — extract Swift Package for fast unit testing

1. Create `FeederCore` Swift Package containing all models, DataWriter, classification logic, FeedbinClient
2. Run unit tests via `swift test` (sub-second execution, no Xcode overhead, no screen takeover)
3. Keep XCUITests only for 2-3 critical E2E paths in the Xcode project
4. Add `make test-fast` target using `swift test`

**Pros:** Dramatically faster test feedback (0.4s vs 25s+), no Aqua session needed for unit tests, clean architecture.
**Cons:** Significant refactoring, must handle SwiftData/Foundation Models dependencies at package boundary, may complicate Xcode project structure.

## 5. Evidence

### Keychain prompt root cause

The Keychain prompt is caused by `CODE_SIGN_IDENTITY=-` (ad-hoc signing). Each build produces a binary with a different code signature, so macOS treats it as a new application requesting Keychain access. The "Always Allow" permission is bound to the previous binary's signature.

Setting `CODE_SIGNING_ALLOWED=NO` completely disables code signing for test builds, which eliminates Keychain interaction entirely. This is safe because:
- Unit tests don't need code signing
- UI tests with `ENABLE_APP_SANDBOX=NO` don't need signing either
- The current Makefile already sets `CODE_SIGNING_REQUIRED=NO` but still allows signing to happen

Source: Apple Developer Forums, GitHub Actions runner-images#1567, community CI configurations.

### XCUITest screen takeover — no solution exists

macOS XCUITests require an Aqua session (interactive GUI login). Apple provides no headless mode for macOS app testing. The test runner uses Accessibility APIs that require foreground access.

Known workarounds:
- Run in a VM (Anka, Parallels) — heavy, not suitable for single-developer workflow
- Run in a separate macOS user session — requires fast user switching, fragile
- Modify TCC.db for Accessibility permissions — requires SIP disable, not recommended
- Accept the limitation and minimize UI test count

The practical answer: **keep UI tests minimal and run them intentionally**, not as part of the default test gate.

### Swift Testing framework compatibility

Swift Testing (`@Test`, `#expect`) works for all non-UI tests. XCUITest requires XCTest and cannot use Swift Testing. Performance tests (`XCTMetric`) also require XCTest. The current split (Swift Testing for unit/integration, XCTest for UI) is correct.

### Test execution times (estimated)

| Target | Estimated time | Notes |
|---|---|---|
| `make lint` | ~2s | swift-format, fast |
| `make build` | ~15-30s | build-for-testing, depends on cache |
| `make test` | ~5-10s | unit tests only, fast |
| `make test-ui` | ~30-60s | launches app 4+ times, takes over screen |
| `make test-all` | ~60-120s | full gate, blocks developer |

## 6. Unknowns

1. **Does `CODE_SIGNING_ALLOWED=NO` work for UI tests?** XCUITest launches the app as a separate process — it may require a signed binary to launch. Need to verify empirically.
   → **This is the single biggest risk.** If UI tests require signing, we need a different approach for the Keychain problem (e.g., custom test keychain, or just accepting the prompt for UI test runs).

2. **Are there DataWriter operations that lack test coverage?** The current tests cover category CRUD comprehensively, but entry operations (persist, classify, mark read, delete old) have zero direct tests. How much of that logic is trivial SwiftData CRUD vs meaningful business logic?

3. **FeederUITestsLaunchTests uses the real app (no demo flags)** — does it actually hit the Keychain? If the app's `init()` doesn't call KeychainHelper when `UITEST_*` flags are absent, it might just show the onboarding screen without Keychain access.

4. **`@Suite(.serialized)` for DataWriter tests** — currently tests are independent (each creates its own in-memory container). If we add shared-state tests, we'll need serialization.

## 7. Recommendation

**Evidence is sufficient to plan.** Recommend **Alternative B (full cleanup)** as the primary path, with the `CODE_SIGNING_ALLOWED=NO` change from A verified first.

Sequencing:
1. **Verify** `CODE_SIGNING_ALLOWED=NO` works for both unit and UI tests (empirical test)
2. **Fix infrastructure** — update Makefile, split test gates, remove launch tests
3. **Prune** low-value tests
4. **Add** missing DataWriter entry operation tests if analysis shows non-trivial logic
5. **Defer** Alternative C (Swift Package extraction) — it's architecturally sound but high-effort and the current test execution time (~10s for unit tests) doesn't justify it yet
