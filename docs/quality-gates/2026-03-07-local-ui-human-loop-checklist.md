# Local UI Human-in-the-Loop Checklist

Date: 2026-03-07
Owner: Repository Owner + Agent
Status: Active

Use this checklist for every UI-facing change in local-only workflow.

## 1) Preview signoff (human)

- [ ] All touched screens/components include `#Preview` blocks.
- [ ] Preview states reviewed in Xcode Canvas (happy + empty/error where applicable).
- [ ] Human approval recorded: `Approved` / `Needs changes`.

## 2) Local automated UX smoke

- [ ] `scripts/local/build-for-testing.sh` passes.
- [ ] `scripts/local/ui-smoke.sh` passes.
- [ ] `.xcresult` generated at `artifacts/local/xcresult/ui-smoke.xcresult`.
- [ ] Summary extracted with `scripts/local/collect-test-artifacts.sh`.

## 3) Behavior checks

- [ ] Primary buttons/actions are clickable.
- [ ] Core list/timeline interaction works (selection + navigation/scroll).
- [ ] Detail view opens for selected item.
- [ ] No obvious layout regressions in reviewed previews.

## Decision

- [ ] GO
- [ ] NO-GO

Notes:

