---
name: implement
description: Execute implementation from an approved plan
user-invocable: true
---

Execute implementation: $ARGUMENTS

## Prerequisites

A research dossier AND an approved plan must exist in the current branch. If either is missing, stop and say which step to run first (`/research` or `/plan`).

## Process

1. Read the plan artifact.
2. Implement each milestone sequentially, committing at checkpoints.
3. After every milestone:
   - Verify build: `bash .claude/scripts/build-for-testing.sh` — must exit 0.
   - Run smoke tests: `bash .claude/scripts/ui-smoke.sh` — must exit 0.
   - If either fails, fix before moving to the next milestone.
4. After all milestones complete, run the full test gate: `bash .claude/scripts/test-all.sh` — must get ALL GREEN.
5. Exit worktree, push branch, and open PR.
6. Spawn a subagent to run `/codereview` against the PR. Fix issues, push, re-run until PASS.
7. Write execution log to `docs/plans/YYYY-MM-DD-<topic>-execution-log.md`.
8. Update `docs/STATUS.md` and `docs/plans/NEXT-ACTIONS.md`.
9. Present to user for human review.
