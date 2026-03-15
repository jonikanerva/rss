# Plan: Agentic macOS Build + UI Test Autonomy

Date: 2026-03-07
Owner: Repository Owner + Agent
Status: Draft
Derived from: Current app architecture review, `docs/operating-model/swift-concurrency-rules.md`, Apple Xcode/XCTest practices

## Scope and goals

- Enable agent sessions to run macOS build and tests autonomously and repeatedly.
- Add deterministic test harness support so UI tests do not depend on live Feedbin or real keychain state.
- Establish CI-quality artifacts (`.xcresult`, logs, screenshots) for reliable triage.
- Keep Swift 6 strict-concurrency guarantees intact.

Out of scope:
- Full visual snapshot testing framework rollout.
- End-to-end tests against production Feedbin in every CI run.
- iOS/iPadOS pipeline.

## Current blockers (baseline)

1. Agent runtime sandbox prevents reliable `xcodebuild`/simulator/tool plugin execution.
2. Code signing requirements and simulator/service permissions create non-deterministic failures in headless runs.
3. App currently has minimal automated tests; UI tests are launch-only templates.
4. Core flows are not yet fully dependency-injected for deterministic UI automation.

## Milestones and dependencies

### M1: Agent execution environment hardening

Goal: Make build/test commands runnable in agent sessions with stable permissions.

Tasks:
- Approve command families for automation:
  - `xcodebuild`
  - `xcrun simctl`
  - `xcrun xcresulttool`
- Ensure writable paths for build/test outputs:
  - `-derivedDataPath /tmp/FeederDerivedData`
  - result bundles under `/tmp` or workspace `artifacts/ci/`
- Define standard command wrappers in repo:
  - `scripts/ci/build-for-testing.sh`
  - `scripts/ci/test-without-building.sh`
  - `scripts/ci/collect-xcresult.sh`

Dependencies:
- Host machine with Xcode + command line tools available.
- Explicit Xcode selection (`xcode-select`/`DEVELOPER_DIR`) documented.

### M2: CI topology for reliable macOS UI tests

Goal: Introduce stable runner strategy.

Tasks:
- Add GitHub Actions workflow using macOS runner (or self-hosted Mac preferred for stability).
- Pin Xcode major/minor version in workflow.
- Run build and tests in split phases:
  1. `xcodebuild build-for-testing`
  2. `xcodebuild test-without-building`
- Always upload artifacts:
  - `.xcresult`
  - test logs
  - screenshots on failure

Dependencies:
- `.github/workflows/` setup.
- Repository secrets/permissions as needed.

### M3: Testability refactor in app (deterministic test mode)

Goal: Make UI and logic tests independent from external services.

Tasks:
- Add dependency injection boundaries for:
  - Feed client
  - credential/keychain access
  - time/clock
  - sync scheduling trigger
- Add launch arguments/environment for test mode:
  - in-memory SwiftData store
  - mock feed data fixtures
  - disable periodic background sync
  - deterministic locale/timezone where needed
- Add accessibility identifiers for primary interaction elements in:
  - onboarding
  - sidebar categories
  - timeline list/group rows
  - article detail
  - settings tabs/actions

Dependencies:
- Light protocol-based abstraction over existing `FeedbinClient` and `KeychainHelper`.

### M4: Automated test suite expansion

Goal: Cover critical user paths with fast, repeatable tests.

Tasks:
- Unit/integration tests:
  - Sync incremental logic (new entries + read-state updates)
  - Classification fallback behavior
  - Grouping clustering behavior
- UI smoke tests (XCTest UI):
  - app launch in test mode
  - category selection updates list
  - selecting entry opens detail
  - settings view opens and saves test credentials/mocks
- Add at least one “regression guard” UI test for the known split-view interaction path.

Dependencies:
- M3 test harness complete.

### M5: Quality gates and operating model integration

Goal: Make autonomy sustainable in daily development.

Tasks:
- Add gate checklist artifact for this initiative under `docs/quality-gates/`.
- Update `docs/operating-model/definition-of-done.md` references in PR template/workflow.
- Define required checks before merge:
  - build-for-testing pass
  - unit/integration suite pass
  - UI smoke suite pass
  - artifact upload success

Dependencies:
- M1-M4 complete enough for enforcement.

## Delivery sequence

1. M1 environment hardening
2. M2 CI topology
3. M3 testability refactor
4. M4 test coverage expansion
5. M5 gate enforcement

## Risks and mitigations

1. Runner flakiness (CoreSimulator/macOS image drift)
   - Mitigation: prefer self-hosted pinned Mac runner; keep hosted runner as fallback lane.
2. UI tests remain brittle due to async background work
   - Mitigation: explicit test mode disables periodic sync and uses deterministic fixtures.
3. Over-coupled app code increases refactor scope
   - Mitigation: introduce narrow protocols first; migrate incrementally.
4. Slow pipeline feedback
   - Mitigation: split smoke UI suite (required) from extended UI suite (scheduled/nightly).
5. Strict concurrency regressions during refactor
   - Mitigation: enforce zero warnings/errors build gate on each milestone PR.

## Acceptance criteria

1. Agent can run build and tests end-to-end via documented scripts without manual Xcode interaction.
2. CI executes:
   - `build-for-testing`
   - `test-without-building`
   - artifact upload
3. UI smoke suite passes deterministically in at least 3 consecutive CI runs.
4. At least 5 meaningful automated tests exist beyond template launch tests.
5. Failures are diagnosable from uploaded `.xcresult` and logs alone.

## Quality gate checklist

- [ ] Command permission/profile for `xcodebuild` + `xcrun` finalized
- [ ] CI workflow added with pinned Xcode version
- [ ] Build-for-testing/test-without-building scripts added
- [ ] Test mode launch args/env implemented
- [ ] Mock/fake feed + keychain paths available for tests
- [ ] Accessibility identifiers added to critical UI surfaces
- [ ] UI smoke tests implemented and passing
- [ ] `.xcresult` + logs + screenshots uploaded on each run
- [ ] Gate artifact recorded in `docs/quality-gates/`

## Evidence and references

- Swift 6 concurrency policy: `docs/operating-model/swift-concurrency-rules.md`
- Xcode CLI testing (build-for-testing/test-without-building): Apple TN2339
- Swift Testing + XCTest UI docs: Apple developer documentation
- GitHub Actions runner guidance: GitHub Docs

