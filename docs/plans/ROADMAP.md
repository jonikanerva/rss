# Delivery Roadmap

Date: 2026-03-02
Updated: 2026-03-04
Owner: Repository Owner + Agent
Status: Active

## Purpose

- Provide a high-level milestone view so any new agent can see sequence, dependencies, and current checkpoint quickly.

## Milestones

1. R1: Research baseline approved
   - Outcome: Research dossier(s) define problem, alternatives, evidence, and recommendation.
   - State: **Complete** — reset dossier + Apple FM comparison research drafted and used.
   - Evidence: `docs/research/2026-03-02-local-llm-classification-reset.md`, `docs/research/2026-03-03-apple-foundation-models-comparison.md`
2. R2: Feasibility spike plan and contracts
   - Outcome: Reduced taxonomy + Feedbin queue + local LLM contract is documented with acceptance criteria.
   - State: **Complete** — plan, gate criteria, and config freeze all in place.
   - Evidence: `docs/plans/2026-03-02-local-llm-classification-reset-plan.md`, `config/categories-v1.yaml`
3. R3: Feasibility implementation evidence
   - Outcome: Reproducible local-LLM categorization artifacts are attached for reset validation.
   - State: **Complete** — run-017 (Apple FM) passes all gate checks. 106 items, 18.9% correction rate.
   - Evidence: `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/`
4. R4: Pre-build gate decision
   - Outcome: GO/NO-GO decision with owner signoff.
   - State: **Complete — GO signed off 2026-03-04**
   - Evidence: `docs/quality-gates/2026-03-02-local-llm-classification-reset-gate-check.md`
5. R5: Hard MVP execution plan lock
   - Outcome: Approved roadmap for full scaffold after gate pass.
   - State: **In progress**

## Critical path

- R1 ✅ -> R2 ✅ -> R3 ✅ -> R4 ✅ -> R5 ⏳

## Dependencies

- R3 depends on stable local benchmark pipeline and reduced taxonomy labels. ✅
- R3 depends on pinned local LLM runtime/model/prompt manifest contract. ✅
- R4 depends on completed artifacts from R3 in one frozen run. ✅
- R5 depends on R4 decision and updated risk posture. ✅

## How to use

- Update milestone states when project phase advances.
- Keep tactical work out of this file; place it in `docs/plans/NEXT-ACTIONS.md`.
