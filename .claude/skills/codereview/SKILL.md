---
name: codereview
description: Review all changes on the current branch against main
context: fork
user-invocable: true
---

Review all changes on the current branch against `main`. **This skill runs as an isolated subagent** — do not rely on any prior conversation context. Derive all understanding from the PR diff and description only.

## Prerequisites

- A PR must exist for the current branch. If not, stop and say: create the PR first.
- Read the PR description, comments, checks, and full diff as your sole inputs. (`gh pr view --comments`, `gh pr diff`, `gh pr checks`)

## Review checklist

Analyze the PR and evaluate:

1. **Scope verification** — does the diff match the PR description? Are there undocumented changes — especially removals, renames, or architectural shifts? Cross-check against any research/plan artifacts included in the PR branch (`docs/research/`, `docs/plans/`).
2. **Security analysis** — injection risks, credential exposure, unsafe data handling, OWASP top 10.
3. **Threat modeling** — what could go wrong in production? Data corruption, migration issues, race conditions, crashes.
4. **Code style** — compliance with code style section in `docs/swift-code-rules.md`.
5. **Swift best practices** — modern Swift 6 patterns, proper actor isolation, correct Sendable conformance.
6. **Architecture compliance** — two-layer rule, no computation in views, predicates pushed to @Query.
7. **App behavior rules** — read `docs/app-rules.md` and verify changes do not violate any locked-down behavioral specs.

## Output

Post a single PR comment (`gh pr review --comment [comment]`) with:

- **PASS** or **FAIL** verdict
- Per-checklist findings (or "No issues" if clean)
- For FAIL: specific file, line, and description for each issue and request the changes (`gh pr review --request-changes --body [comment]`).
- For PASS: approve PR (`gh pr review --approve --body [comment]`).

Every review round gets its own comment — including failed reviews — so there is a permanent audit trail in GitHub.
