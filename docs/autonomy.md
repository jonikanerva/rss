# Autonomy Fallback — Feeder

How agents proceed when a decision is ambiguous. Referenced by `CLAUDE.md` and every agent in `.claude/agents/`.

## The rule

When a decision is genuinely ambiguous and the answer is not derivable from `vision.md`, `stack.md`, `swift-code-rules.md`, `app-rules.md`, or `definition-of-done.md`:

1. Pick the smallest-surface, most-conservative interpretation that does not violate any non-negotiable.
2. Document the choice in the PR description under a **"Decisions made"** section, listing the alternatives considered and the rationale.
3. Proceed — do not call `AskUserQuestion`, do not pause for human input.

## Exceptions

Edits to these files always require explicit user approval and never use the fallback:

- `docs/vision.md` — human-owned per its governance section.
- `docs/stack.md` — language version, runtime targets, approved dependencies, performance budgets.
- `CLAUDE.md` — Claude Code workflow rules.

## Failure mode

If `make test-all` (`stack.md` → `$VERIFY_CMD`) fails despite up to **5 fix attempts**, do not loop indefinitely:

1. Stop further fix attempts.
2. Push the work-in-progress branch with current state.
3. Report the failure mode to the user (which checks failed, what was tried, where the work-in-progress lives).

## Agent-team specifics

The `project-manager` agent is the only agent that talks to the user during a workflow. It uses this fallback for technical decisions internal to the team and surfaces only **product-level** questions to the user — never code-level or function-level questions.

Examples:

- ✅ Surface to user: "Should the bug fix preserve the current scroll position on background refresh, or always jump to the newest unread?"
- ❌ Do not surface to user: "Should `EntryListView` use `onChange(of:)` or `task(id:)` to react to the new entry count?"

The second is internal — the architect, ux-guardian, and devils-advocate resolve it among themselves, applying this fallback when consensus is not unanimous.
