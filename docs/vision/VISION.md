# Product Vision (Canonical)

Date: 2026-02-22
Owner: Repository Owner
Status: Active

## Governance

- `docs/vision/VISION.md` is human-owned.
- Agents must not modify this file without explicit human approval.

## Vision statement

- Build a native macOS RSS app that gives a calm, beautiful, high-trust reading experience.
- Every incoming article is categorized into user-defined main categories and grouped by same story across sources, while strict chronological order is always preserved.

## Product thesis

- The product is a macOS-first RSS reader, not a generic cross-platform feed client.
- The core differentiator is local intelligence:
  - a local/on-device LLM runtime classifies and groups incoming articles.
- The experience is conceptually similar to Techmeme:
  - same-story coverage from multiple sources is grouped under one generated story heading.
- The app remains chronology-first:
  - grouped stories and items are shown in canonical timestamp order (newest first).

## Non-negotiable product outcomes

1. Every ingested article gets a main category assignment (user taxonomy).
2. Every ingested article gets a same-story group assignment.
3. Timeline order is always canonical timestamp descending.
4. AI processing never changes timeline position.
5. Group headers summarize the story and unify cross-source coverage.
6. Categorization and grouping are always on in MVP (no off-toggle).

## UX north star

- Visual quality must feel premium, modern, harmonious, and calm.
- Information hierarchy must be clear at a glance.
- Category views are first-class navigation surfaces.
- Same-story grouping must reduce noise without hiding source diversity.
- Reading flow must feel fast and frictionless for daily use.

## Interaction and accessibility principles

- Keyboard navigation is mandatory and first-class.
- Core actions are fully keyboard-operable.
- Focus behavior is predictable and consistent across views.
- Accessibility is treated as product quality, not post-processing.

## Engineering doctrine (Apple-first)

- Target the newest supported macOS version.
- Prefer the latest Apple platform capabilities and APIs.
- Favor native frameworks and platform conventions over generic abstractions.
- Maintain high code quality: readable architecture, deterministic behavior, strong tests, safe refactors.
- Keep the system observable and reproducible via benchmark/gate artifacts.

## MVP scope (in)

- Feed ingest and normalization.
- Always-on category assignment to user-defined main categories (with explicit fallback path).
- Always-on same-story grouping across sources.
- Category-based timeline views with strict chronology.
- Group headers with generated story titles.
- Reproducible feasibility and quality evidence before broader expansion.

## MVP scope (out)

- Engagement/ranking feeds.
- Popularity/relevance-based alternative sorting.
- Social/collaboration features.
- Multi-platform expansion before macOS core quality and gate targets pass.

## Decision principles

1. Trust over novelty: avoid behavior that damages user confidence.
2. Determinism over opaque heuristics: same input -> same ordering and contract outputs.
3. Product quality over feature count: fewer, better, polished capabilities.
4. Evidence over opinion: key decisions require linked artifacts and gate outcomes.
5. Reversible delivery: small milestones and safe rollback as default.

## Success signals

- Feasibility and quality gates pass with explicit evidence links.
- Grouping quality and chronology invariants are stable across reruns.
- Users can navigate the full core workflow via keyboard.
- UI quality is consistently described as clear, beautiful, and calm in dogfood feedback.

## Canonical usage rule

- This file is the default source for product direction and scope decisions.
- If a proposed change conflicts with this vision, either:
  1) update this file first with human approval, or
  2) document an explicit temporary exception in the active plan.
