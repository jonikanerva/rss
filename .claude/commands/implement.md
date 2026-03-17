Execute implementation: $ARGUMENTS

## Prerequisites

A research dossier AND an approved plan must exist in the current branch. If either is missing, stop and say which step to run first (`/research` or `/plan`).

## Process

1. Read the plan artifact.
2. Implement each milestone sequentially, committing at checkpoints.
3. After every milestone:
   - Verify build: `bash .claude/scripts/build-for-testing.sh` — must exit 0.
   - Run tests: `bash .claude/scripts/ui-smoke.sh` — must exit 0.
   - If either fails, fix before moving to the next milestone.
4. After all milestones complete, spawn a **code review subagent** that reviews the full diff against `main`:
   - Security analysis (injection, credential exposure, unsafe data handling)
   - Threat modeling (crashes, race conditions, data corruption)
   - Code style compliance (code style section in `docs/swift-concurrency-rules.md`)
   - Swift 6 best practices and architecture compliance (two-layer rule)
   - If issues found: fix, commit, re-run review. Repeat until clean.
5. Write execution log to `docs/plans/YYYY-MM-DD-<topic>-execution-log.md`.
6. Update `docs/STATUS.md` and `docs/plans/NEXT-ACTIONS.md`.
7. Push branch and open PR for human review.

Follow all Swift 6 concurrency rules from `docs/swift-concurrency-rules.md`.
