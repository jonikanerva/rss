# Plan: Agent Autonomy and Git Governance Rollout

Date: 2026-02-22
Owner: RPI Orchestrator
Status: Ready for execution
Derived from: `docs/research/2026-02-22-agent-autonomy-git-policy.md`

## Scope and goals

- Define a precise git progression workflow for agent-led development.
- Reduce confirmation overhead for routine commands while preserving safety controls.
- Document explicit decision rights for command execution in local and remote workflows.

## Milestones and dependencies

1. M1: Decision-rights matrix
   - Create clear allow/require-approval/deny lists by command risk tier.
   - Dependency: approved research recommendation.

2. M2: Commit progression protocol
   - Define branch strategy, commit cadence, message conventions, and pre-commit verification.
   - Dependency: M1.

3. M3: Handoff and escalation protocol
   - Define when the agent continues autonomously vs requests user approval.
   - Define rollback default behavior for failed or risky operations.
   - Dependency: M1, M2.

4. M4: Adoption and enforcement hooks
   - Add a practical command checklist and examples.
   - Dependency: M2, M3.

Critical path: M1 -> M2 -> M3 -> M4.

## Risks and mitigations

1. Policy too permissive causes unsafe writes.
   - Mitigation: default-deny for destructive, production, billing, IAM, and secret-affecting actions.

2. Policy too strict keeps current slowdown.
   - Mitigation: explicit auto-allow for local read commands and low-risk local quality checks.

3. Inconsistent commit quality across tasks.
   - Mitigation: require logical milestone commits and verification before commit.

## Acceptance criteria

- `docs/operating-model/decision-rights.md` includes explicit risk tiers and approval boundaries.
- `docs/operating-model/handoff-protocol.md` includes commit progression steps and escalation triggers.
- Policy includes concrete command examples for both auto-allow and approval-required cases.
- Rollback path is documented for any operation that writes to git history or remote.

## Quality gate checklist

- [ ] Research dossier approved in `docs/research/`.
- [ ] Plan approved in `docs/plans/`.
- [ ] Operating-model docs updated and internally consistent.
- [ ] Safety constraints align with repository git rules and protected-branch assumptions.
