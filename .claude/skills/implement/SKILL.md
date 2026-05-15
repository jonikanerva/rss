---
name: implement
description: >
  Full implement-and-ship workflow. Use when asked to implement a feature,
  fix a bug, or make any code change that should be shipped as a PR.
  Does not include planning — use /plan mode first for non-trivial work.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent
argument-hint: <description of what to implement>
---

# Implement and Ship Workflow

Complete workflow for implementing a change and shipping it as a PR.
The task description comes from `$ARGUMENTS`.

Communicate in Finnish with the user. All code artifacts (commits,
branch names, PR text, code comments) in English per
`CLAUDE.md → Language Policy`.

## Procedure

Follow these steps in order. Do not skip steps.

### Step 1: Run the decision filter

Before writing any code, read `docs/vision.md → Non-negotiable product outcomes` and `docs/vision.md → Decision principles`. The change must honor all six non-negotiable outcomes and pass the four decision principles (product quality over feature count; opinionated single way; evidence over opinion; reversible delivery).

Also scan `docs/swift-code-rules.md → Strict Prohibitions` and `docs/stack.md → Approved dependencies`. If the task requires anything in the rejected list (new third-party dependencies not in `docs/stack.md`, `@unchecked Sendable`, `nonisolated(unsafe)`, force-unwraps, etc.), stop and propose the smallest framework-native alternative that complies. Do NOT silently violate these.

If a conflict exists between the task and these files, apply `docs/autonomy.md`: pick the smallest-surface conservative interpretation that does not violate any non-negotiable, and document the choice in the PR description under a **"Decisions made"** section.

### Step 2: Ensure feature branch

Check the current branch:

```
git branch --show-current
```

- If on `main`: create and switch to a feature branch. Derive the
  branch name from the task. Use `feat/<slug>`, `fix/<slug>`,
  `chore/<slug>`, or `docs/<slug>`. Keep under 50 characters,
  lowercase, hyphens only.
- If already on a feature branch: stay on it. Run
  `git log main..HEAD --oneline` to understand the current state.

**NEVER commit or push to `main` directly.** The settings.json deny-list and hooks block this, but do not rely on them — use the right branch.

### Step 3: Implement the change

Implement what is described in `$ARGUMENTS`, following all project
standards:

- `docs/swift-code-rules.md → Two-Layer Architecture` — all writes go through `DataWriter`, no `ModelContext` on MainActor.
- `docs/swift-code-rules.md → Actor Boundaries` — DTOs across actors are `nonisolated struct` + `Sendable`.
- `docs/swift-code-rules.md → Mandatory Patterns` — every async path is cancellation-safe.
- `docs/swift-code-rules.md → Strict Prohibitions` — no `@unchecked Sendable`, `nonisolated(unsafe)`, force-unwraps outside tests/previews, `print()`, `TODO`/`FIXME`/`HACK`, commented-out code.
- `docs/app-rules.md → Performance` — no heavy work on MainActor (no regex/loops/Calendar math in `body`); predicates pushed to `@Query`.
- `docs/app-rules.md → Keyboard Navigation` — every new surface is fully keyboard-operable.
- `docs/app-rules.md → Vanilla macOS` — native SwiftUI components, system colors, system fonts.
- `docs/stack.md → Logging & privacy` — never log PII; use `.private` interpolation for user-derived values.
- `docs/stack.md → Approved dependencies` — no new third-party dependency without an entry here.
- Every new feature or behavior change gets tests (`docs/swift-code-rules.md → Core Principles`).
- Every UI surface that gains new states gets SwiftUI previews for each state in `docs/definition-of-done.md → UI states`.

### Step 3.1: Autonomy fallback (no AskUserQuestion)

If the task is unclear or ambiguous:

1. Pick the smallest-surface, most-conservative interpretation that does not violate any non-negotiable (`docs/autonomy.md`).
2. Document the choice in the PR description under a **"Decisions made"** section, listing the alternatives considered and the rationale.
3. Proceed.

**Do not call `AskUserQuestion`.** The autonomous flow depends on this.

Exceptions that always require explicit user approval (never use the fallback): edits to `docs/vision.md`, `docs/stack.md`, or `CLAUDE.md` (per `docs/autonomy.md → Exceptions`).

### Step 4: Run verification

```
make test-all
```

The exact composition is declared in `docs/stack.md → Build & verify commands`. **All must pass with zero warnings.**

If verification fails:

1. Read the error output carefully.
2. Fix the underlying issue — do NOT suppress warnings with `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, `MainActor.assumeIsolated`, or any equivalent escape hatch (`docs/swift-code-rules.md → Strict Prohibitions`).
3. Re-run `make test-all`.
4. Repeat until all checks pass.
5. **Maximum 5 fix attempts** (`docs/autonomy.md → Failure mode`). If still failing on attempt 6, do not loop indefinitely:
   - Stop further fix attempts.
   - Push the work-in-progress branch with the current state.
   - Report the failure mode to the user in Finnish: which checks failed, what was tried, where the work-in-progress lives.
   - Do **not** call `AskUserQuestion`.

### Step 5: Commit

Stage only the files related to this change. **NEVER** use `git add -A`
or `git add .` blindly. Review what is being staged.

**NEVER** commit `.env` files, credentials, or secrets.

Write commit messages that:

- Follow Conventional Commits: `<type>(<scope>): <summary>`.
- Are concise (1-2 sentences).
- Focus on "why" not "what".
- Are in English.

Each commit must be one complete logical unit. If multiple logical
changes were made, create separate commits — one per logical unit.

### Step 6: Push

```
git push -u origin <branch-name>
```

### Step 7: Create or update PR

Check if a PR already exists for this branch:

```
gh pr list --head <branch-name> --json number,url --jq '.[0]'
```

**If no PR exists**, create one using `gh pr create --title "<title>" --body "<body>"`. The body must follow `.github/pull_request_template.md` and include:

- **Why** — motivation; which `docs/*.md` section drove the change.
- **What** — brief technical summary.
- **Rules involved** — list the specific `docs/*.md` sections and sub-rules touched (e.g. `docs/swift-code-rules.md → Two-Layer Architecture`, `docs/app-rules.md → Keyboard Navigation`).
- **States handled** — if the change affects UI, list the states from `docs/definition-of-done.md → UI states` that the change handles (loading, success, empty, error, offline, permission-blocked).
- **Verification** — `make test-all` passed; any preview states added; tests added; privacy declaration updated if applicable.
- **Decisions made** — only if `docs/autonomy.md` was applied; list alternatives considered and rationale.

Keep the title under 70 characters.

**If a PR already exists**, add a comment summarising what changed:

```
gh pr comment <number> --body "<what changed and why>"
```

### Step 8: Report to user

Tell the user in Finnish (the only Finnish artifact — everything written to the repo or GitHub is English):

- Summary of what was implemented.
- Verification results (all passing).
- PR URL.
- Suggest: "Aja `/codereview` kun olet valmis reviewiin."

## Rules

- **NEVER** push to `main`.
- **NEVER** commit secrets, credentials, `.env` files, or values forbidden by `docs/stack.md → Logging & privacy`.
- **NEVER** merge the PR — that happens after review and manual testing (`gh pr merge` is allowed only when the user explicitly asks).
- **NEVER** weaken `SWIFT_STRICT_CONCURRENCY` or other strictness settings declared in `docs/stack.md`.
- If `make test-all` does not pass within 5 attempts, do NOT push or create the PR — abandon the branch per Step 4.
- If the decision filter fails, do NOT implement — document, surface, and rewrite the task to the smallest acceptable shape.
- **NEVER** call `AskUserQuestion`.
