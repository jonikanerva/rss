# Hard MVP Plan: Always-On Categorization + Grouping

Date: 2026-02-21
Owner: RPI Orchestrator
Status: Draft for approval

## Scope and goals

- Build a macOS RSS app where two capabilities are non-negotiable and always on:
  - Categorization of every ingested item into user-defined main categories.
  - Same-story grouping for cross-source coverage.
- Preserve strict chronological ordering everywhere:
  - All views are sorted by canonical timestamp descending (newest first).
  - AI never reorders timeline position.
- Coverage-first MVP contract:
  - Every item has `category`, `group`, and `canonical_timestamp`.
  - Fallback paths are allowed in MVP, silent dropping is not.

## Non-goals

- No unread counters, urgency badges, or engagement ranking.
- No alternative sort modes (popularity/relevance) in MVP.
- No optional toggle to disable categorization/grouping.
- No scope expansion to social, collaboration, or multi-platform parity before gates pass.

## Milestones and dependencies

1. M1: Canonical chronology contract
   - Define timestamp precedence and schema fields.
   - Add invariant tests for strict ordering.
   - Dependency: none.

2. M2: Always-on categorization baseline
   - Baseline classifier, confidence handling, fallback assignment.
   - Store provenance (`model` vs fallback) per assignment.
   - Dependency: M1.

3. M3: Always-on grouping baseline
   - Deterministic grouping key policy and assignment pipeline.
   - Group timestamp = newest item in group.
   - Dependency: M1, stability signals from M2.

4. M4: Integration hardening and quality gates
   - End-to-end contract tests, replay/backfill checks, telemetry.
   - Gate review and go/no-go decision.
   - Dependency: M1-M3.

Critical path: M1 -> M2 -> M3 -> M4.

## Architecture boundaries

- Keep ingestion and storage foundation stable; prefer additive schema changes.
- Enforce chronology in both data layer and UI layer.
- UI must render server/store order without secondary sorting.
- Keep categorization/grouping modular so model runtime can evolve without changing timeline contract.

## Risks and mitigations

1. Timestamp inconsistency across feeds breaks chronology.
   - Mitigation: explicit timestamp precedence rules and deterministic normalization.

2. Categorization drift destabilizes grouping quality.
   - Mitigation: taxonomy versioning, fallback policy, correction logging.

3. False merges reduce trust.
   - Mitigation: conservative merge policy, evidence-based thresholds, ambiguity handling.

4. Backfill/live divergence introduces regressions.
   - Mitigation: replay parity checks and idempotent processing.

## Acceptance criteria

- Chronology:
  - All category and all-items views strictly newest -> oldest.
  - Group expand/collapse does not reorder neighboring timeline items.
- Categorization:
  - 100% item coverage with category (model or fallback).
  - Manual correction path exists and is keyboard-operable.
- Grouping:
  - 100% item coverage with group assignment.
  - Group header reflects newest timestamp in that group.
- UX:
  - Read state is subtle and calm; no unread count surfaced.

## Quality gate checklist

- [ ] Research dossier approved in `docs/research/`.
- [ ] Gate thresholds approved in `docs/quality-gates/`.
- [ ] Taxonomy and grouping specs versioned.
- [ ] Evaluation dataset and labeling protocol frozen for v1.
- [ ] Go/no-go review recorded with owner signoff.
