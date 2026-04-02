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
   - Verify build: `make build` — must exit 0.
   - Run smoke tests: `make test-ui` — must exit 0.
   - If either fails, fix before moving to the next milestone.
4. After all milestones complete, run the full test gate: `make test-all` — must get ALL GREEN.
5. Exit worktree, push branch, and open PR (`gh pr create --base main --title [title] --body [body]`).
6. Spawn a subagent to run `/codereview` against the PR. Fix all found issues, push branch, add a PR comment (`gh pr comment --body [comment]`) on the implemented fixes, re-run codereview until PASS.
7. Write execution log to `docs/plans/YYYY-MM-DD-<topic>-execution-log.md`.
8. Update `docs/plans/NEXT-ACTIONS.md`.
9. Present to user for human review. Do not merge until human approves the review.
