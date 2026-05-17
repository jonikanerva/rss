# Product Vision (Canonical)

Date: 2026-05-17
Owner: Repository Owner
Status: Active

## Governance

- `VISION.md` is human-owned.
- Agents must not modify this file without explicit human approval.

## Vision statement

- Build a native macOS RSS app that gives a calm, beautiful, high-trust reading experience.
- Every incoming article is categorized into user-defined main categories, while strict chronological order is always preserved.

## Product thesis

- The product is a macOS-first RSS reader, not a generic cross-platform feed client.
- The core differentiator is local intelligence:
  - a local/on-device LLM runtime classifies incoming articles into user-defined categories.
- The app remains chronology-first:
  - articles are shown in canonical timestamp order (newest first), within and across categories.

## Non-negotiable product outcomes

1. Every ingested article gets exactly one main category assignment (user defined taxonomy).
2. Timeline order is always canonical timestamp descending.
3. AI processing never changes timeline position.
4. Categorization is always on in MVP (no off-toggle).

## UX north star

- Visual quality must feel premium, modern, harmonious, and calm.
- Information hierarchy must be clear at a glance.
- Category views are first-class navigation surfaces.
- Reading flow must feel fast and frictionless for daily use.
- One good benchmark Current Reader (https://www.currentreader.app/)

## Interaction and accessibility principles

- Keyboard navigation is mandatory and first-class.
- Core actions are fully keyboard-operable.
- Focus behavior is predictable and consistent across views.
- Accessibility is treated as product quality, not post-processing.

## Engineering doctrine (Apple-first)

- Target the newest supported macOS version. MacOS 26.
- Prefer the latest Apple platform capabilities and APIs.
- Favor native frameworks and platform conventions over generic abstractions.
- Maintain high code quality: readable architecture, deterministic behavior, strong tests, safe refactors.
- Keep the system observable and reproducible via benchmark/gate artifacts.

## MVP scope (in)

- Feed ingest and normalization only via Feedbin so we get the full-content of the article via the API.
- Uses Apple Foundation Models or OpenAI for on-device / cloud classification. Both are first-class options the user chooses between. OpenAI is currently the higher-quality choice; Apple Foundation Models is the zero-config, fully on-device alternative.
- Category assignment to user-defined main categories (with explicit fallback path).
- Each article is assigned to exactly one main category — the best match. Multi-label assignment is out of scope for MVP.
- Category-based timeline views with strict chronology.
- Reproducible feasibility and quality evidence before broader expansion.

## MVP scope (out)

- Every other feature not listed in MVP scope (in)

## Decision principles

1. Product quality over feature count: fewer, better, polished capabilities.
2. Opionated, one way to use it, let's make the decision and avoid complexity.
3. Evidence over opinion: key decisions require linked artifacts and gate outcomes.
4. Reversible delivery: small milestones and safe rollback as default.

## Success signals

- LLM is able to categorize articles. Human verifiable.
- UI quality is consistently described as clear, beautiful, and calm in dogfood feedback.

## Canonical usage rule

- This file is the default source for product direction and scope decisions.
- If a proposed change conflicts with this vision update this file first with human approval
