# Next Actions (Execution Queue)

Date: 2026-02-22
Owner: Repository Owner + Agent
Status: Active

## Rules

- Keep exactly 1 item `In progress`.
- Keep maximum 3 active items total (`In progress` + `Ready`).
- Every item includes owner, acceptance check, and target checkpoint.
- Move completed items to the history section with date and evidence link.

## Active queue

1. [In progress] Grouping quality metrics to benchmark output
   - Owner: Agent
   - Acceptance check: benchmark `metrics.json` includes grouping quality fields and tests pass.
   - Target checkpoint: next commit slice

2. [Ready] Reproducible feasibility run (frozen snapshot)
   - Owner: Agent
   - Acceptance check: required files exist under `artifacts/feasibility/<run-id>/`.
   - Target checkpoint: after item 1 passes

3. [Ready] Gate evidence linkage and decision log update
   - Owner: Product owner + Engineering owner
   - Acceptance check: gate document includes evidence links and explicit GO/NO-GO decision.
   - Target checkpoint: after item 2

## Completed history

- 2026-02-22: Worktree-per-session default documented in operating model.
  - Evidence: `docs/operating-model/handoff-protocol.md`, `docs/operating-model/cadence.md`
- 2026-02-22: Multi-agent git isolation research drafted.
  - Evidence: `docs/research/2026-02-22-multi-agent-git-isolation-options.md`

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update `docs/STATUS.md` in the same change.
