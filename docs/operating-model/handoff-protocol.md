# Handoff Protocol: Commit Progression and Escalation

Date: 2026-02-22
Owner: Repository Owner + Agent
Status: Active draft

## Purpose

Define how work progresses from local edits to review-ready commits with minimal interruption and predictable handoffs.

## Branch and commit progression

1. Start from updated base and create task branch.
   - Naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `chore/<topic>`.
2. Implement one logical change at a time.
3. Run local verification for changed scope.
4. Create single-purpose commit with clear message.
5. Repeat until task scope is complete.
6. Push branch and open PR.

## Commit cadence

- Commit at logical milestones, usually every 30-90 minutes of focused work.
- Avoid mixed-purpose commits.
- Keep commit history reviewable: why-first, what-second.

## Commit message convention

Use Conventional Commit style:

```text
<type>(<scope>): <imperative summary>
```

Examples:

- `docs(operating-model): define agent decision-right tiers`
- `chore(ci): enforce gate-check artifact validation`

## Pre-commit verification minimum

Before each commit, run the smallest meaningful checks:

- Formatter/linter for touched files.
- Targeted tests for impacted behavior.
- If no tests exist, run relevant smoke command.

If checks fail:

- Do not commit until fixed, or
- Commit only if explicitly agreed and message explains temporary failure context.

## Escalation triggers (ask user)

Agent pauses and asks for explicit confirmation when:

- Requested command is Tier B or Tier C from decision rights.
- Action would modify protected branch or shared remote history.
- Action impacts production/runtime data outside local environment.
- Security-sensitive data might be exposed or committed.

## Rollback defaults

- Preferred rollback: `git revert <sha>` for already committed branch changes.
- For uncommitted local mistakes: safe targeted edits (avoid destructive reset unless explicitly requested).
- Never force-push `main`; avoid force push on any branch unless explicitly requested.

## PR handoff checklist

- [ ] Branch is pushed and tracks remote.
- [ ] Commits are single-purpose and readable.
- [ ] Verification commands and outcomes are recorded in PR description.
- [ ] Risks/assumptions are stated.
- [ ] Reviewer can reproduce validation steps.
