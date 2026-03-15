# Plan: Local-Only Human-in-the-Loop UI Validation

Date: 2026-03-07
Owner: Repository Owner + Agent
Status: Draft
Derived from: UI testing discussion, existing app architecture, `docs/operating-model/swift-concurrency-rules.md`

## Scope and goals

- Keep all UI validation local (no GitHub CI / external CI required).
- Require human approval for every UI change via Xcode Preview validation.
- Automate local UX smoke checks (buttons, navigation, scrolling, core interactions) with XCTest UI tests.
- Preserve Swift 6 strict-concurrency rules and current app architecture direction.

Out of scope:
- External cloud CI pipelines.
- Fully autonomous visual approval without human review.
- Pixel-perfect snapshot framework rollout in this phase.

## Working model (decision)

1. Agent implements UI changes + preview scenarios.
2. Human validates previews in Xcode Canvas and approves/rejects.
3. Agent runs local automated UX smoke suite to confirm interactivity and regressions.
4. Change is accepted only when both human preview signoff and local UX smoke pass.

## Milestones and dependencies

### M1: Preview coverage standard for every screen

Goal: Every user-facing view has explicit `#Preview` coverage for key states.

Tasks:
- Define preview standard in code comments/docs:
  - happy path
  - empty state
  - loading/busy state (if applicable)
  - error/fallback state (if applicable)
- Add reusable preview fixtures (feeds, entries, groups, categories).
- Ensure each major screen has at least one stable preview block:
  - `ContentView`
  - `EntryDetailView`
  - `EntryRowView`
  - `OnboardingView`
  - `SettingsView`
  - `CategoryManagementView`

Dependencies:
- Lightweight fixture factory for sample models.

### M2: Deterministic local test mode

Goal: UI tests are stable and do not depend on live Feedbin, real credentials, or background timing noise.

Tasks:
- Add launch arguments/environment flags, for example:
  - `UITEST_MODE=1`
  - `UITEST_FIXTURE_SET=baseline`
  - `UITEST_DISABLE_PERIODIC_SYNC=1`
  - `UITEST_IN_MEMORY_STORE=1`
- Add dependency injection boundaries for:
  - feed client
  - credential/keychain provider
  - clock/timing hooks
- Disable/override periodic sync in UI test mode.

Dependencies:
- Small protocol layer around current concrete services.

### M3: Local automation scripts (no CI)

Goal: One-command local build + UX smoke execution with artifacts.

Tasks:
- Add local scripts:
  - `scripts/local/build-for-testing.sh`
  - `scripts/local/ui-smoke.sh`
  - `scripts/local/collect-test-artifacts.sh`
- Use split execution:
  1. `xcodebuild build-for-testing`
  2. `xcodebuild test-without-building`
- Save artifacts locally:
  - `.xcresult` under `artifacts/local/xcresult/`
  - parsed summary text/json under `artifacts/local/test-reports/`
  - failure screenshots from UI tests

Dependencies:
- Agent permission to run local `xcodebuild` and `xcrun xcresulttool`.

### M4: UX smoke test suite for interaction regressions

Goal: Automatically verify that core usability paths still work.

Tasks:
- Add `accessibilityIdentifier` to all interaction-critical elements.
- Implement local UI smoke tests for:
  - app launch + initial screen visible
  - category selection updates visible list
  - entry selection opens detail
  - list can scroll up/down
  - key actions/buttons respond (sync/settings/category actions)
  - settings tab navigation works
- Add regression test for known split-view interaction path.

Dependencies:
- M2 deterministic test mode + M1 preview fixtures.

### M5: Human signoff gate for UI changes

Goal: Institutionalize human approval before merge.

Tasks:
- Add signoff checklist artifact for UI tasks under `docs/quality-gates/`.
- Require each UI PR/task to include:
  - preview evidence list (which previews were reviewed)
  - manual approval note by human
  - latest local UX smoke result summary
- Define fail rule:
  - no merge if preview signoff missing
  - no merge if local UX smoke fails

Dependencies:
- M1-M4 complete enough for repeatable execution.

## Suggested local commands

```bash
# Build once for tests
xcodebuild -project Feeder.xcodeproj -scheme Feeder -configuration Debug -derivedDataPath /tmp/FeederDerivedData CODE_SIGNING_ALLOWED=NO build-for-testing

# Run UI smoke without rebuilding
xcodebuild -project Feeder.xcodeproj -scheme Feeder -configuration Debug -derivedDataPath /tmp/FeederDerivedData CODE_SIGNING_ALLOWED=NO test-without-building -resultBundlePath artifacts/local/xcresult/ui-smoke.xcresult

# Optional: extract summary
xcrun xcresulttool get --path artifacts/local/xcresult/ui-smoke.xcresult --format json > artifacts/local/test-reports/ui-smoke.json
```

## Risks and mitigations

1. Preview coverage drifts when new screens are added
   - Mitigation: “no preview, no UI merge” rule in signoff checklist.
2. UI tests flaky due to async/background work
   - Mitigation: deterministic test mode, disable periodic sync, stable fixtures.
3. Local environment differences between sessions
   - Mitigation: pin Xcode version and standardize local scripts/derived data paths.
4. Manual signoff becomes inconsistent
   - Mitigation: fixed checklist template under `docs/quality-gates/`.

## Acceptance criteria

1. Every major UI screen has `#Preview` blocks covering key states.
2. Human can validate UI from Xcode Canvas and record approval per change.
3. Local UX smoke test suite runs from scripts with no external CI service.
4. UX smoke covers core interaction paths (tap/click/scroll/navigation).
5. Local run produces `.xcresult` and readable summary artifacts.

## Quality gate checklist

- [ ] Preview standard documented and applied to all major screens
- [ ] Deterministic `UITEST_MODE` implemented
- [ ] Service dependencies injectable for test mode
- [ ] Accessibility identifiers added for critical controls
- [ ] Local build-for-testing/test-without-building scripts added
- [ ] Local UX smoke suite implemented and passing
- [ ] Human preview signoff checklist added under `docs/quality-gates/`
- [ ] UI changes blocked without both signoff + smoke pass

