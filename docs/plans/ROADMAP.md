# Delivery Roadmap

Date: 2026-02-22
Owner: Repository Owner + Agent
Status: Active draft

## Purpose

- Provide a high-level milestone view so any new agent can see sequence, dependencies, and current checkpoint quickly.

## Milestones

1. R1: Research baseline approved
   - Outcome: Research dossier(s) define problem, alternatives, evidence, and recommendation.
   - State: Complete
2. R2: Feasibility spike plan and contracts
   - Outcome: Chronology, categorization, and grouping contract is documented with acceptance criteria.
   - State: Complete
3. R3: Feasibility implementation evidence
   - Outcome: Reproducible benchmark artifacts and quality metrics are attached.
   - State: In progress (pipeline complete, awaiting human review for C4 evidence)
4. R4: Pre-build gate decision
   - Outcome: GO/NO-GO decision with owner signoff.
   - State: Blocked on R3 (human review)
5. R5: Hard MVP execution plan lock
   - Outcome: Approved roadmap for full scaffold after gate pass.
   - State: Pending

## Critical path

- R1 -> R2 -> R3 -> R4 -> R5

## Current bottleneck

- **R3 → R4 transition** is blocked on human dogfood review of 303 real RSS items (`data/eval/dogfood-v1/review-sheet.csv`). All automated pipeline metrics pass. The only missing evidence is the C4 Human Trust Proxy (correction rate from real reviewed sample).

## Dependencies

- R3 depends on stable benchmark pipeline and dataset labels.
- R4 depends on completed artifacts from R3 in one frozen run.
- R5 depends on R4 decision and updated risk posture.

## How to use

- Update milestone states when project phase advances.
- Keep tactical work out of this file; place it in `docs/plans/NEXT-ACTIONS.md`.
