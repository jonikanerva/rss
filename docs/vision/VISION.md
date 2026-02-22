# Product Vision (Canonical)

Date: 2026-02-22
Owner: Repository Owner
Status: Active

## Governance

- `docs/vision/VISION.md` is human-owned.
- Agents must not modify this file without explicit human approval.

## Vision statement

- Build a calm, trustworthy macOS RSS experience where every item is categorized and grouped by same story without breaking strict chronology.

## Non-negotiable product outcomes

1. Every ingested item has a main category assignment.
2. Every ingested item belongs to a same-story group.
3. Timeline order is always canonical timestamp descending (newest first).
4. AI processing never reorders timeline position.

## MVP scope (in)

- Always-on categorization with fallback path (no silent drop).
- Always-on same-story grouping with conservative merge behavior.
- Chronology invariants enforced in data and UI.
- Reproducible feasibility evidence and explicit gate decision before full scaffold expansion.

## MVP scope (out)

- Unread counters and urgency ranking.
- Alternative timeline sorting modes (popularity/relevance).
- Optional toggles to disable categorization or grouping.
- Scope expansion to social/collaboration before gate pass.

## Decision principles

1. Trust over cleverness: avoid false merges that damage user confidence.
2. Determinism over hidden heuristics: same input should produce same order and contract fields.
3. Evidence over opinion: release decisions require linked artifacts and gate checks.
4. Small reversible steps: milestone commits and safe rollback (`git revert`) by default.

## Success signals

- Feasibility gate C1-C5 passes in one frozen run.
- Grouping quality metrics are included in benchmark output and tracked in gate evidence.
- New agent can identify current phase and next actions in under 10 minutes via `docs/STATUS.md`.

## Canonical usage rule

- Use this file as the default vision source in planning and scope decisions.
- If a change conflicts with this vision, update this file first or document an explicit exception in the active plan.
