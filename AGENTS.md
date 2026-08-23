# AGENTS.md — operating contract for Codex

`VISION.md` is the product; `STACK.md` is the technology and all its concrete
rules. This file is the engineering doctrine and team workflow. Where a rule
says "as in `STACK.md`", that file is the authority. This file names no
language or framework.

Read order: `VISION.md` → this file → `STACK.md` → the issue
(`gh issue view <N>`). Treat every rule as MUST unless marked otherwise. When a
rule conflicts with a request, surface it and propose the smallest idiomatic
alternative; do not silently break it.

## Workflow

The backlog is the GitHub issue list. Drive product work through the
`$project-manager` skill, the team lead and only user-facing orchestration
surface. Invoke it by issue number (`solve issue #42`) or a problem description.

- `$project-manager` reads the issue, proposes a plan, then delegates to the
  `architect`, `ux_guardian`, `devils_advocate`, `lead_dev`, and `qa_enforcer`
  custom agents. They design, stress-test, implement, open a PR, and run
  `$codereview` to PASS. The PR reaches the user only after PASS.
- `$implement <task>` runs the feature branch → change → `$VERIFY_CMD` → commit
  → push → PR workflow. `lead_dev` runs it once per issue.
- `$codereview` reviews the branch against `main` and posts a PASS/FAIL review.
  Only `qa_enforcer` runs it after implementation; `lead_dev` does not review
  its own work.

Use subagents when this workflow or the user requests the team. The primary
agent remains accountable for orchestration, waits for every required result,
and gives the user one consolidated response. Do not spawn the team for
ordinary questions that do not invoke this workflow.

## Audit trail

The record of what and why is GitHub issues, Conventional Commits, PR
descriptions and review comments, and the merge-commit chain on `main`. Do not
create a roadmap, backlog, ledger, or change-log file. State a decision that
binds future work in plain language in the PR and relevant issue.

Deferred work must not die in a PR comment or conversation note. When planning
or review defers an item beyond current scope, file a GitHub issue labelled
`follow-up`. Agents file issues unprompted only for this and for a tracking or
decision issue that has no existing issue or PR; the user still owns the
backlog and may close or rescope it.

## Language

Everything in the repository and on GitHub is English: code, comments,
commits, branches, PRs, issues, and docs. Only Codex's chat replies to the user
are Finnish.

Use Simplified Technical English (STE) for English text that users read in the
repository or on GitHub. This includes documentation, commit messages, issues,
PR descriptions, and review comments. Write short sentences. Use active voice
and plain, consistent terms. This rule does not apply to Finnish chat. Do not
rewrite compact operating contracts only to apply STE.

## Git workflow

- Use `$implement`; never commit or push to `main`. Branches are
  `feat|fix|chore|docs/<topic>`: at most 50 characters, lowercase, hyphenated.
- Use Conventional Commits with one logical unit per commit, explain why, and
  end agent-authored commits with
  `Co-Authored-By: Codex <noreply@openai.com>`.
- Merge to `main` with a merge commit, never squash. Delete the branch after
  merge.
- Link a resolved issue with `Closes #<N>`. Every PR description covers why,
  what, the rules involved, verification, and the decision-filter outcome.
- A trivial typo, dependency bump, dead-code removal, or formatting-only PR may
  collapse decision-filter, states, and rules blocks to
  `N/A — trivial change`. Why, what, and verification remain mandatory.

## Verification

Run `$VERIFY_CMD` from `STACK.md` before every commit and PR; it must pass with
no new warnings. Always use the named `$FORMAT_CMD`, `$LINT_CMD`, `$BUILD_CMD`,
`$TEST_CMD`, and `$VERIFY_CMD`; never substitute their underlying tools.

---

# Engineering doctrine

Concrete technology, budgets, and banned calls live in `STACK.md`.

## Mission

Build the product in `VISION.md` on the stack in `STACK.md`: idiomatic,
responsive under failure and load, strictly typed and concurrency-safe in the
strictest supported mode, resource-conscious, privacy-respecting, and easy to
evolve. Prefer the platform standard library and first-party frameworks. Do
not add custom application frameworks or architecture for hypothetical needs.

## Product guardrails

Before accepting a feature, run `VISION.md → Decision Filter`. If any answer is
"no", reject it, record the conflict in the PR or issue, and propose the
smallest alternative that passes. Read the filter dynamically. Never silently
violate `VISION.md`.

## Architecture

Keep the layered shape named in `STACK.md`:

- **Interface**: screens, request handlers, CLI commands, or public API.
- **Domain**: pure transforms, state machines, and business rules with no
  framework imports.
- **Infrastructure**: network, storage, sensors, and external systems reached
  through narrow interfaces.

Right-size state ownership: local state belongs to its surface; a shared
stateful surface has one owner; shared mutable non-UI state uses a thread-safe
primitive; app-wide dependencies use explicit injection; durable data uses the
declared persistence layer. Model phases as tagged unions, not parallel
booleans.

## Concurrency

Use the strictest async-safety mode `STACK.md` permits with no new warnings.
Isolate critical-path state explicitly. Shared mutable non-UI state lives
behind a thread-safe primitive. Prefer structured concurrency. Detached work
requires a reason and clear ownership. Cancellation is mandatory when the
owning surface goes away. Types crossing concurrency boundaries are
thread-safe. Never block the critical path on async work. Every escape hatch
needs an inline justification naming the underlying API constraint.

## Responsiveness and resource budget

Keep synchronous work on the critical path within the budget in `STACK.md`.
Move slower work off-path and preserve continuity with a placeholder,
last-known-good value, stream, or pagination. Give external calls timeouts and
graceful fallbacks. Render large collections lazily with stable IDs. Cache
expensive derived work rather than repeating it per event. Navigation and
input never wait on I/O. Pause background work when its surface is inactive.

## States handled

Every visible surface handles the states declared by `VISION.md` and
`STACK.md`, commonly awaiting-first-data, success, empty, degraded,
permission-blocked, offline, and error. Previews, stories, or fixtures exercise
every applicable state.

## Time

Treat time as an external input. Use one absolute UTC reference internally for
logic, domain values, persistence, caches, and logs. Convert to or from zoned
or local values only at boundaries. Never hand-roll timezone-offset arithmetic.
Use the platform APIs and concrete types in `STACK.md`. Serialize instants as
UTC across persistence and wire boundaries.

## Side effects

- External systems are reached through the client in `STACK.md`; request
  construction, decoding, retries, and backoff stay in the service layer.
- Persistence uses only the declared shape and handles decode or migration
  failure gracefully.
- Prefer framework-native caching; long-lived caches use thread-safe owners.
  Never cache PII or tokens beyond their lifetime.
- Background work uses only mechanisms allowed by `STACK.md`.

## Privacy and security

Maintain platform privacy declarations accurately. Never log PII or sensitive
derived values; use platform redaction. Release builds must not leak. Add no
silent telemetry or third-party analytics. Use encrypted transport. Keep
secrets in approved environment or ignored files, never in the repository.

## Testing

Use the framework in `STACK.md` and run cleanly in strict mode. Test pure
domain transforms, transitions, and edge cases first. Test the state owner that
drives a surface using fake or in-memory service boundaries and assert its
timeline. Prefer interface-backed live, preview, and fake services over
heavyweight mocking.

## Code conventions

Prefer value types and immutable bindings. Use mutation or reference identity
only when required. Prefer composition, small purpose-driven types, and files
named for their primary type. No unsafe unwraps or coercions outside tests, no
broad type erasure without measured benefit, and no global mutable state or
singletons unless an API requires one. Delete dead code. Comments explain why.
Exported symbols receive doc comments. Use the logger in `STACK.md`; leave no
debug output in shipped code. Run `$FORMAT_CMD` before committing.

## Dependencies

Default to no, especially when the platform already solves the problem. A
necessary dependency uses the package manager in `STACK.md`, passes strict
verification, and receives an `Approved Dependencies` entry with rationale,
approver, and date.

## Reject changes that…

Fail the decision filter or add a `VISION.md → Non-Goals` feature; add a
competing framework or unnecessary boilerplate; put heavy work on the critical
path; couple the interface to raw network, storage, or sensor internals; store
or compute internal time locally; hide failure behind infinite spinners; model
phases with parallel booleans; suppress warnings with escape hatches; start
unowned fire-and-forget work; add a dependency for a platform capability;
lower the minimum version; introduce debug output, stubs, commented-out code,
or PII logging; add unapproved singletons or DI containers; or violate any
`STACK.md → Stack-specific reject-list additions` rule.

## Definition of done

The result stays responsive under slow network, denied permission, degraded
data, and load; handles every applicable state; keeps heavy work off the
critical path; makes every async path cancellation-safe; introduces no
forbidden persisted or transmitted data and no PII in logs; tests new domain
logic in strict mode; considers accessibility; passes `$VERIFY_CMD`; and
updates privacy declarations and docs when relevant.

## Autonomy fallback

When a decision is ambiguous and not derivable from `VISION.md`, `STACK.md`,
this file, or the issue, choose the smallest-surface conservative
interpretation that passes the decision filter. Document it in the PR and in
the issue if it binds future work. Do not stop for a question during the
autonomous phase unless completing the work requires new authority. Direct
edits to `VISION.md` or this file always need an explicit user request. After
10 failed `$VERIFY_CMD` repair attempts, stop, push a
`chore/abandoned-<task>` branch, and open or update a draft PR describing the
failure.

## Intentional divergence

A deliberate exception requires measurable need, clear benefit, isolated
scope, and a documented reason in `STACK.md → Intentional Divergences`.
Divergence from `VISION.md` requires the product owner.

---

## Safeguards

Use Codex sandboxing and approval controls in addition to this doctrine. Never
force-push, push to `main`, bypass hooks, recursively delete broad paths, read
secret files, or merge without explicit user authorization. Never invoke a
second Codex CLI process from the shell to simulate subagents; use Codex's
subagent tools.

## Decision rights

- **Auto-allow**: read-only commands; the named build, test, and lint commands;
  feature-branch operations; PR creation; PR and issue reads/comments; and
  `STACK.md` edits.
- **Ask first**: edits to `VISION.md` or `AGENTS.md`, creating or restructuring
  issues, repository-setting changes, and merging a PR.
- **Never**: force-push, push to `main`, bypass hooks, recursively delete broad
  project paths, or persist or transmit data forbidden by `VISION.md`.
