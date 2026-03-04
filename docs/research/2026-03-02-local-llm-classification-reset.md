# Research: Local LLM Classification Reset

Date: 2026-03-02
Owner: Repository Owner + Agent
Status: Active

## Problem and users

- Previous validation data included synthetic benchmark content that is not suitable for manual trust review.
- We need to validate if a local LLM can classify real Feedbin articles according to `docs/vision/VISION.md`.
- Primary users are dogfood reviewers and product/engineering owners making GO/NO-GO calls.

## Constraints and assumptions

- Classification runs locally using a pinned local runtime/model.
- Category set should be small and clear during reset phase.
- Manual review sample must contain real articles and reach at least 300 reviewed rows.

## Alternatives and tradeoffs

1. Keep previous broad taxonomy (rejected for reset)
- Higher expressive power, lower label consistency in manual review.

2. Use reduced top-level taxonomy (selected)
- Better consistency and faster review cycles, at the cost of lower granularity.

## Evidence and source links

- Product direction and constraints: `docs/vision/VISION.md`
- Feed source snapshot: `config/feedbin-feeds-v1.json`
- Active fetch profile: `config/feedbin-fetch-profile-v1.json`
- Label definitions with LLM context: `config/categories-v1.yaml`

## Recommendation

- Reset to one focused proof loop: real Feedbin review queue, reduced labels, and deterministic local LLM run evidence.
- Remove historical benchmark artifacts from active scope and keep only reset-phase files.
