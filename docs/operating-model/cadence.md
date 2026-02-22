# Cadence: Team + Agent Working Rhythm

Date: 2026-02-22
Owner: Repository Owner + Agent
Status: Active draft

## Purpose

Define a predictable execution rhythm so work moves quickly with low interruption and clear checkpoints.

## Daily rhythm

1. Start by syncing branch context (`git status`, target scope, blockers).
2. Execute one scoped task at a time on a feature branch.
3. Commit at logical milestones (typically every 30-90 minutes).
4. Run targeted verification before each commit.
5. Push and hand off when a reviewable slice is ready.

## Checkpoint cadence

- Short tasks: one reviewable commit + PR.
- Medium tasks: 2-5 milestone commits.
- Longer efforts: daily push with status note and next checkpoint.

## Verification cadence

- Before commit: smallest meaningful formatter/lint/test checks.
- Before PR: full scope checks required by repo conventions.
- Before merge: CI green and reviewer signoff.

## Escalation cadence

Agent asks immediately when:

- Action enters Tier B/Tier C decision rights.
- Scope changes affect production, security, billing, or secrets.
- Requirements become ambiguous enough to alter user-visible outcomes.

## Communication defaults

- Progress updates stay concise and action-oriented.
- Each handoff states: what changed, what was verified, and what remains.
- Risks/assumptions are surfaced at the first relevant checkpoint.
