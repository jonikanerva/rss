# Research Dossier: Evaluation Dataset Spec and Labeling Protocol

Date: 2026-02-21
Owner: RPI Orchestrator
Status: Draft for approval

## Problem and users

- We need a trustworthy truth set to evaluate two non-negotiable capabilities:
  - Categorization into user-defined main categories.
  - Same-story grouping across sources.
- Primary user in this phase: first power-user dogfooder.
- Secondary users: product and engineering owners who need go/no-go evidence.

## Constraints and assumptions

- Limited initial labeling capacity (1-2 people).
- False merges are more trust-damaging than false splits for first dogfood.
- Taxonomy can evolve; strict versioning is mandatory.
- Data is RSS/news-like and includes rewrites, updates, and near-duplicates.

## Alternatives and tradeoffs

1. Single annotator, single pass
   - Pros: fastest.
   - Cons: weak confidence and no agreement signal.

2. Full dual-annotation with adjudication on 100%
   - Pros: strongest reliability.
   - Cons: slower and expensive for first dogfood.

3. Hybrid stratified consensus (recommended)
   - Full set single-labeled, high-impact slice dual-labeled, conflicts adjudicated.
   - Best speed/quality balance for this phase.

## Recommended dataset specification

- Taxonomy track (item-level):
  - Size: 300-500 items.
  - Label: primary category (+ optional secondary).
  - Stratified by source, recency, and ambiguity.

- Same-story track (pair-level):
  - Size: 400-700 pairs.
  - Label: `same_story`, `different_story`, `uncertain`.
  - Target mix: hard positives 35-45%, clear negatives 35-45%, hard negatives 15-25%.

- Versioning:
  - Freeze regression split as `v1`.
  - Maintain challenge split for edge cases.
  - Track `taxonomy_version`, `guideline_version`, `labeler_id`, `adjudicator_id`, `labeled_at`.

## Labeling protocol

- Calibration pilot:
  - 30-50 taxonomy items.
  - 40-60 same-story pairs.

- Main pass:
  - Single-label full set.
  - Dual-label 20-30% stratified slice.

- Adjudication:
  - Resolve all disagreements and policy-defining edge cases.
  - Freeze dataset v1 after guideline updates.

## Evidence and source links

- Inter-annotator agreement: https://aclanthology.org/J08-4004/
- Cohen's kappa reference: https://scikit-learn.org/stable/modules/generated/sklearn.metrics.cohen_kappa_score.html
- Precision/recall/F1 guidance: https://developers.google.com/machine-learning/crash-course/classification/accuracy-precision-recall
- News similarity benchmark context: https://aclanthology.org/2022.semeval-1.164/
- Dataset documentation best practices: https://arxiv.org/abs/1803.09010
- Consensus workflow reference: https://docs.labelbox.com/docs/consensus

## Recommendation

- Adopt the hybrid stratified consensus approach for v1 dogfood evidence.
- Run a focused calibration session with the first dogfooder on ambiguous examples before freezing v1.
- Use frozen `v1` set for all gate decisions to prevent threshold drift.
