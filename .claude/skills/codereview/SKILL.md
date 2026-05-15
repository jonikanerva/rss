---
name: codereview
description: Review all changes on the current branch against main. Posts an audit-grade PASS/FAIL comment to the PR.
context: fork
user-invocable: true
---

Review all changes on the current branch against `main`. **This skill runs as an isolated subagent** — do not rely on any prior conversation context. Derive all understanding from the PR diff, description, check output, and the project's governance files only.

Communicate in Finnish when reporting progress to the user. Write the PR-review comment itself in English (project policy: all PR artifacts are in English — see `CLAUDE.md → Language Policy`).

## Prerequisites

- A PR must exist for the current branch. If not, the autonomy fallback applies: do NOT call `AskUserQuestion`. Instead, run `gh pr create` against the current branch with a minimal title / body derived from the latest commit, then proceed. (The lead-dev should already have done this; the fallback is for races where it has not.)
- Read: `gh pr view --comments`, `gh pr diff`, `gh pr checks`, and the governance files `docs/vision.md`, `docs/stack.md`, `docs/swift-code-rules.md`, `docs/app-rules.md`, `docs/definition-of-done.md`, `docs/autonomy.md`, `CLAUDE.md`, `README.md`.
- Inspect the branch history with `git log main..HEAD --oneline`.
- Prefer reviewing the whole changed surface, not only the displayed diff hunk. Follow call sites, state ownership, service boundaries, tests, previews, build scripts, and configuration touched by the change.

## Quality standard

The bar is the quality target stated in `docs/vision.md → Non-negotiable product outcomes`, `docs/definition-of-done.md`, and `docs/stack.md → Performance budgets`.

**Every blocking finding is a FAIL.** A blocking finding is any rule-backed defect, regression risk, missing required evidence, security / privacy issue, production failure mode, required-test gap, unsupported dependency / build-system change, or mismatch with the PR's stated scope.

Do **not** fail a PR for subjective taste, personal style, or a possible alternative that is not clearly better under the local rules. If an observation is not actionable, not tied to the diff, or not tied to a violated project rule / material risk, omit it from the PR comment. This review is a merge gate, not a brainstorming session.

## Review lenses

Evaluate every PR through these lenses. Use the lenses to organize your reasoning; convert them into findings only when the evidence meets the blocking-finding bar.

1. **Functional correctness** — Does the changed code do what the PR claims? Are edge cases, empty inputs, invalid data, permission denial, retries, cancellation, and migration paths correct?
2. **Product and scope fit** — Does the change satisfy `docs/vision.md → Decision principles`, avoid `docs/vision.md → MVP scope (out)`, and stay inside the non-negotiable product outcomes?
3. **Architecture and maintainability** — Does it preserve the two-layer shape in `docs/swift-code-rules.md → Two-Layer Architecture`, local ownership, obvious state flow, small purpose-driven types, and framework-native primitives?
4. **Concurrency and lifecycle safety** — Does it satisfy `docs/swift-code-rules.md → Actor Boundaries` and Mandatory Patterns? UI-thread isolation, structured concurrency, cancellation, thread-safe boundary types (DTOs as `nonisolated struct` + `Sendable`).
5. **Security and privacy** — Does it avoid credential exposure, broken access control, PII leakage, overbroad permissions, forbidden persistence, and unsafe transport / logging? See `docs/stack.md → Logging & privacy`.
6. **Reliability and failure modes** — Does it behave under slow network, degraded dependencies, missing permissions, first launch, cold start, backgrounding, low memory, and partial failure? Are all states in `docs/definition-of-done.md → UI states` covered?
7. **Performance and resource budget** — Does it avoid hot-path work, MainActor blocking, unbounded SwiftUI body work, excessive allocation? Honor `docs/stack.md → Performance budgets` and `docs/app-rules.md → Performance`.
8. **Test adequacy** — Do tests cover new domain logic, state transitions, edge cases, async timelines, and regression risks? See `docs/swift-code-rules.md → Core Principles`.
9. **Supply-chain and dependency risk** — Are dependencies approved (`docs/stack.md → Approved dependencies`), build scripts safe, generated artifacts justified?
10. **Operability and observability** — Are errors actionable, logs privacy-safe (`.private` interpolation per `docs/stack.md → Logging & privacy`), hot paths measurable, silent failures avoided?
11. **Accessibility and inclusive UX** — For UI surfaces, does the change honor dynamic / large text, screen reader semantics, focus order, contrast, reduced motion, and keyboard operability per `docs/app-rules.md → Keyboard Navigation`?
12. **AI / agent behavior** — If the PR adds LLM, prompt, retrieval, or autonomous-agent behavior (Foundation Models, OpenAI provider per `docs/vision.md`), does it handle prompt injection, sensitive-data flow, output validation, and fail-closed behavior?

## Reference mapping

The project governance files in `docs/` are the primary source of truth. External standards are supporting references, not a replacement for local rules. Use them only when they materially apply to the changed surface.

- **OWASP ASVS / OWASP Top 10** — authentication, authorization, input handling, session management, crypto, error handling, logging.
- **OWASP Cheat Sheet Series** — concrete implementation guidance for validation, output encoding, secrets, transport security.
- **CWE Top 25** — precise code-level weakness classification when a finding matches a known weakness.
- **WCAG 2.2 / EN 301 549** — perceivable, operable, understandable, robust UI for any user-facing surface.
- **OWASP Top 10 for LLM Applications** — prompt injection, sensitive information disclosure, unsafe output handling for LLM features.
- **Apple Human Interface Guidelines** — vanilla macOS conformance per `docs/app-rules.md → Vanilla macOS`.

Do not cite a standard just to make a finding look stronger. The finding must stand on local evidence first. The reference mapping explains why the risk matters and gives the author a known remediation frame.

## Fact verification

Every finding must be grounded in evidence. Specifically:

- **Findings about the project's own rules** are grounded in the governance files — cite the section (`docs/swift-code-rules.md → Two-Layer Architecture`, `docs/vision.md → Non-negotiable product outcomes`, `docs/stack.md → Approved dependencies`, etc.). The files in the repo are the source of truth for project rules.
- **Findings that turn on external-tool behavior** — what a SwiftData API requires, how `@MainActor` propagation works, what a `gh` flag does, what `xcodebuild` parses, what an accessibility standard currently says — must be verified against **current official documentation** before being recorded. Use `ctx7` per `~/.claude/rules/context7.md` for Apple frameworks and library docs.
- If the docs contradict the assumption, drop the finding.
- If the docs are silent or ambiguous after a reasonable lookup, report it as "could not verify" in a separate verification note rather than asserting it as a failure. Let the author decide.

This rule is narrow. It governs factual claims about how a system works or what an external standard requires. Style preferences, architectural critique, and rule compliance against the governance files still belong in the checklist below and are evaluated on judgment.

## Specific zero-tolerance rules

The following are blocking findings when present in changed production code or required project artifacts:

- Dead code, unused imports, orphaned helpers, unreachable paths, or placeholder implementation.
- Code duplication when a shared helper exists or a small extraction clearly removes real duplication.
- `TODO` / `FIXME` / `HACK` / `XXX` comments, commented-out code, debug `print()`, or `fatalError("TODO")`.
- Force-unwraps / `as!` outside tests and previews.
- Concurrency / type-check escape hatches (`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, `MainActor.assumeIsolated`) without an inline justification comment that names the underlying-API constraint forcing it (`docs/swift-code-rules.md → Strict Prohibitions`).
- Identifier whose meaning contradicts the function / type's documented responsibility, or that reuses a name already bound to a different concept.
- Inconsistency with established patterns in the codebase without local justification.
- Logging of PII or values forbidden by `docs/stack.md → Logging & privacy`.
- New dependency, build step, or generated artifact that is not documented in `docs/stack.md → Approved dependencies`.

## Review checklist

Evaluate the PR against all of these. **Every missed required check is a FAIL.**

1. **Scope verification** — Does the diff match the PR description? Are there undocumented changes, especially removals, renames, build changes, generated files, dependency changes, data-flow changes, or architectural shifts?

2. **Vision alignment** — Read `docs/vision.md → Non-negotiable product outcomes` and `docs/vision.md → Decision principles`. Verify the PR honors all six product outcomes and does not pull the product toward `docs/vision.md → MVP scope (out)`.

3. **Functional correctness** — Verify the changed behavior against the stated requirement, surrounding code, edge cases, invalid inputs, empty states, first launch, repeated actions, partial failure.

4. **Security & privacy** — Check credential exposure, overbroad access, unsafe output handling, PII leaks in logs (use `.private` per `docs/stack.md → Logging & privacy`), `PrivacyInfo.xcprivacy` updates if a new data flow was introduced, no `.env` content in the diff.

5. **Threat modeling and reliability** — Ask what could go wrong in production: race conditions, degraded-data masking bugs, missing-permission paths, crashes on first launch, lifecycle bugs, stale caches, unbounded retries, idempotency failures, inconsistent recovery after cancellation.

6. **Code style and maintainability** — Check compliance with `.swift-format` and `docs/swift-code-rules.md → Code Style`. Enforce small types, clear naming, immutable bindings where practical, no force-unwraps, comments that explain why, no cleverness without measurable benefit.

7. **Swift 6 concurrency / Sendable** — Check `docs/swift-code-rules.md → Actor Boundaries` and Mandatory Patterns: MainActor default isolation, all writes through `DataWriter` (no `ModelContext` on MainActor), DTOs across actors are `nonisolated struct` + `Sendable`, every async path cancellation-safe, no escape hatches.

8. **UI / API responsiveness** — Check `docs/app-rules.md → Performance` and `docs/stack.md → Performance budgets`: no heavy work in `body` (regex, loops, Calendar math), predicates pushed to `@Query`, lists virtualize, navigation does not wait on network / storage.

9. **Architecture compliance** — Check `docs/swift-code-rules.md → Two-Layer Architecture`: one state owner per screen, pure domain code, services isolate external systems, views do not consume raw persistence internals.

10. **Apple platform conformance** — Check `docs/app-rules.md`: keyboard navigation works for new surfaces, native SwiftUI components (no custom chrome where standard solves the problem), system colors and system fonts, Apple's current best practices verified via `ctx7`.

11. **Dead code, duplication, leftover markers** — Scan the diff and touched files for unused functions, variables, parameters, imports, orphaned helpers, copy-paste of existing helpers, `TODO` / `FIXME` / `HACK` / `XXX`, commented-out code, placeholder strings, debug `print()`. Zero avoidable debt at merge.

12. **Tests** — Check `docs/swift-code-rules.md → Core Principles`: pure domain code has edge-case coverage; state holders driving screens are tested with fakes; async paths and cancellation-sensitive flows have tests where practical; all tests are strict-concurrency clean.

13. **Supply-chain risk** — Check dependency additions, generated files, build scripts. Any new non-first-party dependency must be in `docs/stack.md → Approved dependencies`.

14. **Operability and observability** — Check that failures are visible to the user at the right level, logs are structured and privacy-safe, errors are actionable, and no important failure is swallowed silently.

15. **Accessibility** — For changes to UI surfaces, verify dynamic / large text, screen reader labels and roles, focus order, contrast against the project palette, reduced-motion respect, color-independence, keyboard operability (`docs/app-rules.md → Keyboard Navigation`).

16. **AI / agent surfaces** — If the change adds LLM (Foundation Models, OpenAI), prompt, model-output, or autonomous-agent behavior, check prompt-injection exposure, sensitive-data flow, output validation, fail-closed behavior. Map to OWASP LLM Top 10 only when relevant.

## Finding format

Every blocking finding in the PR comment must use this format:

```md
### <Checklist item>: <short finding title>

- **Location:** `<file>:<line>`
- **Evidence:** <what the diff or surrounding code shows>
- **Impact:** <production risk or rule consequence>
- **Local rule:** `<docs/*.md or CLAUDE.md section>`
- **External reference:** <official standard or docs URL when materially applicable, otherwise `N/A`>
- **Minimum fix:** <smallest change that resolves the issue>
- **Verification:** <test, check, preview, or command that proves the fix>
```

Do not include findings that cannot be tied to a concrete location, PR metadata item, or changed project artifact. For PR-level issues, use `PR description`, `branch history`, or `CI checks` as the location.

## Output

Post every review as a plain PR comment. The PASS / FAIL verdict lives as the first line of the comment body.

```sh
gh pr review --comment --body "<comment>"
```

Do not use `--approve` or `--request-changes`: GitHub rejects those when the reviewer is also the PR author, which is the common case here. Plain comments work regardless of authorship and still produce a permanent audit-trail entry on the PR.

The comment body starts with one of:

- `**Verdict: PASS**` — every required check passed cleanly and no blocking findings exist.
- `**Verdict: FAIL**` — at least one blocking finding exists.

Then list every blocking finding with the required finding format. Group by checklist item.

If there are no blocking findings but an external fact could not be verified, add a short `Verification notes` section after the verdict. Do not turn uncertainty into a failure unless a local project rule requires explicit evidence and that evidence is missing.

**PASS means zero blocking findings across all checklist items.** Do not categorize PR findings as "nitpick", "minor", or "suggestion". Either the issue is a blocking finding with evidence, impact, rule, fix, and verification, or it is omitted from the merge-gate comment.

Every review round gets its own PR comment — including failed ones — so there is a permanent audit trail on GitHub.

Finally, report to the user in Finnish (Claude's chat replies are the only Finnish artifact — the PR comment itself is English):

- Verdict (PASS / FAIL).
- Number of blocking findings if FAIL.
- Link to the review comment on GitHub.
- For FAIL: suggest running `/codereview` again after fixing.

## Autonomy fallback

If a check is genuinely ambiguous and the local rules do not clearly resolve it, default to **FAIL only when merge would require accepting an unverified production, privacy, security, workflow, or correctness risk**. Otherwise omit the issue or record it as a verification note. Apply `docs/autonomy.md` — pick the smallest-surface, most-conservative interpretation. Do not call `AskUserQuestion`.
