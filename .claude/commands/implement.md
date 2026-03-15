Execute implementation from the approved plan: $ARGUMENTS

## Prerequisites

- A research dossier and an approved plan must exist. If either is missing, stop and tell the user which `/research` or `/plan` step to run first.

## Execution constraints

- Implement tasks in the order specified by the plan.
- Keep changes minimal and focused — do not add scope.
- Report verification evidence for each completed task.
- The build must remain clean (zero errors, zero warnings) after every change.
- Follow all Swift 6 strict concurrency rules from `docs/operating-model/swift-concurrency-rules.md`.

## Process

1. Read the referenced plan artifact.
2. Create a worktree and feature branch.
3. Implement each milestone sequentially, committing at each checkpoint.
4. Write implementation notes to `docs/plans/YYYY-MM-DD-<topic>-execution-log.md`.
5. Update `docs/STATUS.md` and `docs/plans/NEXT-ACTIONS.md` when done.
