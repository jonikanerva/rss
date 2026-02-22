# Delivery Roadmap

Date: 2026-02-22
Owner: Repository Owner + Agent
Status: Active draft

## Purpose

- Provide a high-level milestone view so any new agent can see sequence, dependencies, and current checkpoint quickly.

## Milestones

1. R1: Research baseline approved
   - Outcome: Research dossier(s) define problem, alternatives, evidence, and recommendation.
   - State: In progress
2. R2: Feasibility spike plan and contracts
   - Outcome: Chronology, categorization, and grouping contract is documented with acceptance criteria.
   - State: In progress
3. R3: Feasibility implementation evidence
   - Outcome: Reproducible benchmark artifacts and quality metrics are attached.
   - State: In progress
4. R4: Pre-build gate decision
   - Outcome: GO/NO-GO decision with owner signoff.
   - State: Pending
5. R5: Hard MVP execution plan lock
   - Outcome: Approved roadmap for full scaffold after gate pass.
   - State: Pending

## Critical path

- R1 -> R2 -> R3 -> R4 -> R5

## Dependencies

- R3 depends on stable benchmark pipeline and dataset labels.
- R4 depends on completed artifacts from R3 in one frozen run.
- R5 depends on R4 decision and updated risk posture.

## How to use

- Update milestone states when project phase advances.
- Keep tactical work out of this file; place it in `docs/plans/NEXT-ACTIONS.md`.
