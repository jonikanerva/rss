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

## Quality standard

This project targets premium code quality. Every finding — regardless of severity — is a FAIL. There is no "nitpick", "minor", "suggestion", or "consider fixing later" category. If something can be improved, it must be improved before merge.

Specific zero-tolerance rules:
- No dead code, unused imports, or orphaned helpers
- No code duplication when a shared helper exists or should be extracted
- No TODO/FIXME/HACK comments, commented-out code, or debug print statements
- No unclear naming — every function, variable, and type should read naturally
- No unnecessary complexity — if simpler code achieves the same result, flag it
- No inconsistency with existing patterns in the codebase

## Review checklist

Analyze the PR and evaluate:

1. **Scope verification** — does the diff match the PR description? Are there undocumented changes — especially removals, renames, or architectural shifts?
2. **Security analysis** — injection risks, credential exposure, unsafe data handling, OWASP top 10.
3. **Threat modeling** — what could go wrong in production? Data corruption, migration issues, race conditions, crashes.
4. **Code style** — compliance with code style section in `docs/swift-code-rules.md`.
5. **Swift best practices** — modern Swift 6 patterns, proper actor isolation, correct Sendable conformance.
6. **Architecture compliance** — two-layer rule, no computation in views, predicates pushed to @Query.
7. **Design principles** — read `docs/app-rules.md` and verify changes respect all four design principles (performance, keyboard navigation, vanilla macOS, readability).
8. **Dead code** — does the PR introduce or leave behind unused functions, variables, parameters, imports, or unreachable code paths? Check that removed features don't leave orphaned helpers. Grep the repo for callers when uncertain.
9. **Duplication** — does the PR copy-paste logic that already exists in the codebase? Check for near-identical patterns by grepping for key expressions from new code. Flag when a shared helper exists or should be extracted.
10. **Leftover markers** — scan the diff for TODO, FIXME, HACK, XXX comments, commented-out code blocks, placeholder strings, and `print()` debug statements. Zero debt at merge — every marker must be resolved or removed.
11. **Naming & clarity** — are new names (functions, variables, types) precise and self-documenting? Is the code easy to read without comments? Could any logic be simplified?

## Output

Post a single PR comment (`gh pr review --comment [comment]`) with:

- **PASS** or **FAIL** verdict
- Per-checklist findings (or "No issues" if clean)
- For FAIL: specific file, line, and description for each issue and request the changes (`gh pr review --request-changes --body [comment]`).
- For PASS: approve PR (`gh pr review --approve --body [comment]`).

**PASS means zero findings across all 11 checks.** One finding in any category — no matter how small — is a FAIL with requested changes. Do not categorize findings as "nitpick", "minor", or "suggestion". Every finding is a required fix.

Every review round gets its own comment — including failed reviews — so there is a permanent audit trail in GitHub.
