# Project Status (Single Source of Truth)

Read this file first at session start.

Date: 2026-03-04
Owner: Repository Owner + Agent
Status: Active

## Current phase

- All 5 MVP milestones complete. Ready for dogfood.

## Active objective

- Owner dogfoods the app daily for 1 week with real Feedbin account. Subjective quality feedback: "clear, beautiful, and calm."
- Open `Feeder.xcodeproj` in Xcode to build and run.

## Success criteria for current objective

- App builds and runs on macOS 26.
- Feedbin sync works with real account.
- Classification runs on all synced English articles.
- Same-story grouping produces meaningful clusters.
- Keyboard navigation covers all core actions.
- Owner rates experience as "clear and calm" after 1 week of daily use.

## Completed milestones

1. **M1: Scaffold + Feedbin sync** — PR #2 merged. SwiftUI app, Feedbin API client, SwiftData persistence, background sync.
2. **M2: Classification engine** — PR #3 merged. Apple FM `@Generable` classification, user-defined categories, category management UI.
3. **M3: Same-story grouping** — PR #4 merged. GroupingEngine with Jaccard clustering, timeline integration.
4. **M4: Timeline + category views** — PR #5 merged. Keyboard navigation, visual polish, refined typography.
5. **M5: Polish + dogfood** — PR #6 merged. Status bar, tabbed settings, sync interval, accessibility labels.

## Next actions (max 3)

1. [In progress] Hierarchical categories + category management UX.
   - Owner: Agent
   - Context: Branch `feat/hierarchical-categories`. Implementation complete. Awaiting PR + manual testing.
   - Acceptance: Build passes. 2-level hierarchy in sidebar and settings. Inline editing. Drag reorder. Deepest-match classification.

2. [Ready] Owner dogfood for 1 week.
   - Owner: Repository Owner
   - Context: Open `Feeder.xcodeproj` in Xcode, build and run. Authenticate with Feedbin, use daily.
   - Acceptance: Subjective quality feedback after 1 week.

## Active artifact pointers

- Research: `docs/research/2026-03-16-hierarchical-categories.md`
- Plan: `docs/plans/2026-03-16-hierarchical-categories-plan.md`
- Execution log: `docs/plans/2026-03-16-hierarchical-categories-execution-log.md`

- Vision: `docs/vision/VISION.md`
- Execution plan: `docs/plans/2026-03-04-hard-mvp-execution-plan.md`
- App source: `Feeder/` (native Xcode project, open `Feeder.xcodeproj` in Xcode)
- Research: `docs/research/2026-03-02-local-llm-classification-reset.md`
- Research: `docs/research/2026-03-03-apple-foundation-models-comparison.md`
- Gate: `docs/quality-gates/2026-03-02-local-llm-classification-reset-gate-check.md`
- Category definitions: `pre_planning/config/categories-v1.yaml`
- Feasibility evidence: `pre_planning/artifacts/feasibility/run-017-apple-fm-tighter-descriptions/`

## Last updated

- 2026-03-16 by Claude agent (Hierarchical categories: 2-level hierarchy, inline editor, drag reorder, deepest-match classification.)
