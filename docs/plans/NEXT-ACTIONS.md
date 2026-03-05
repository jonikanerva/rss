# Next Actions (Execution Queue)

Date: 2026-03-04
Owner: Repository Owner + Agent
Status: Active

## Rules

- Keep exactly 1 item `In progress`.
- Keep maximum 3 active items total (`In progress` + `Ready`).
- Every item includes owner, acceptance check, and target checkpoint.
- Move completed items to the history section with date and evidence link.

## Active queue

1. [In progress] Incremental sync: unread-first phased sync
   - Owner: Agent
   - Acceptance check: First sync shows categorized unread articles within ~10 seconds. Recent history backfills in background.
   - Target checkpoint: PR merged
   - Context: Branch `feat/incremental-sync`. Research: `docs/research/2026-03-05-incremental-sync-strategy.md`. Plan: `docs/plans/2026-03-05-incremental-sync-plan.md`.

2. [Ready] Dogfood the app for 1 week
   - Owner: Repository Owner
   - Acceptance check: Owner uses app daily with real Feedbin account. Subjective quality feedback: "clear, beautiful, and calm."
   - Target checkpoint: 1 week of daily use
   - Context: Open `Feeder.xcodeproj` in Xcode, build and run. All 5 milestones complete (PRs #2–#6), project restructured to native Xcode project (PR #8).

## Completed history

- 2026-03-04: M5 polish merged (PR #6). Status bar, tabbed settings, sync interval, accessibility.
- 2026-03-04: M4 timeline polish merged (PR #5). Keyboard navigation, visual hierarchy, reading width.
- 2026-03-04: M3 story grouping merged (PR #4). GroupingEngine, Jaccard clustering, timeline integration.
- 2026-03-04: M2 classification merged (PR #3). Apple FM @Generable, user-defined categories, auto-classify.
- 2026-03-04: M1 scaffold merged (PR #2). SwiftUI app, Feedbin API, SwiftData, background sync.
- 2026-03-04: R5 Hard MVP plan approved by owner.

- 2026-03-04: Gate thresholds adjusted and run-017 evaluated — all checks pass, GO pending signoff.
  - Evidence: `docs/quality-gates/2026-03-02-local-llm-classification-reset-gate-check.md`
  - Key changes: Reviewed rows 300→106, removed F1/Jaccard/fallback rate, greedy sampling accepted as determinism evidence, reduced required artifacts to 4.
- 2026-03-04: R4 gate GO signed off by owner. Advancing to R5.
  - Evidence: `docs/quality-gates/2026-03-02-local-llm-classification-reset-gate-check.md`
  - Key changes: Reviewed rows 300→106, removed F1/Jaccard/fallback rate, greedy sampling accepted as determinism evidence, reduced required artifacts to 4.
  - Evidence: `docs/quality-gates/2026-03-02-local-llm-classification-reset-gate-check.md`
  - Key changes: Reviewed rows 300→106, removed F1/Jaccard/fallback rate, greedy sampling accepted as determinism evidence, reduced required artifacts to 4.
- 2026-03-04: Apple FM run-017 passes correction rate gate (106 items, 20 corrections, 18.9% rate).
  - Evidence: `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/dogfood-corrections.csv`, `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/decision-log.md`
  - Key changes: Improved category descriptions (user-editable lever); generic system prompt with "assign broader categories alongside specific ones"; tightened ai/world descriptions to reduce over-assignment.
- 2026-03-04: Apple FM prompt tuning runs (014, 015, 016, 017) explored description vs prompt tradeoffs.
  - Evidence: `artifacts/feasibility/run-014-apple-fm-multi-label/`, `artifacts/feasibility/run-016-apple-fm-improved-descriptions/`, `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/`
  - Key insight: System prompt must be generic (works for any user-defined categories). Quality improvements come from category descriptions, not prompt engineering.
- 2026-03-04: Apple FM run-013 dogfood review complete (106 items, 29 corrections, 27.4% rate — FAILS gate).
  - Evidence: `artifacts/feasibility/run-013-apple-fm-english-only/dogfood-corrections.csv`, `artifacts/feasibility/run-013-apple-fm-english-only/decision-log.md`
  - Key findings: Apple FM under-assigns broad categories (technology 24 vs Ollama 62), over-uses "other" as secondary, misses cross-domain labels (ai+world, gaming+gaming_industry).
- 2026-03-04: Apple FM comparison runs completed (run-011, run-012, run-013).
  - Evidence: `artifacts/feasibility/run-013-apple-fm-english-only/metrics.json`
  - Key changes: 10x faster than Ollama, contentTagging adapter rejected, language detection + body truncation added.
- 2026-03-03: Full-content candidate frozen with determinism evidence (run-010).
  - Evidence: `artifacts/feasibility/run-010-llama3.2-3b-full-content/decision-log.md`, `artifacts/feasibility/run-010-llama3.2-3b-full-content/dataset-manifest.json`
  - Key changes: full-content extraction queue (106 items, 54 extracted, 0 excerpt-only), context window increased from 1024 to 4096 to prevent prompt truncation.
- 2026-03-03: Generic prompt candidate frozen with determinism evidence.
  - Evidence: `artifacts/feasibility/run-009-llama3.2-3b-generic-prompt/decision-log.md`, `artifacts/feasibility/run-009-llama3.2-3b-generic-prompt/dataset-manifest.json`
- 2026-03-03: Recalibration candidate locked from early manual sample.
  - Evidence: `artifacts/feasibility/run-006-llama3.2-3b/decision-log.md`, `artifacts/feasibility/run-0084-llama3.2-3b-apple-guardrail-only/decision-log.md`
- 2026-03-03: Exploratory recalibration runs completed from early manual sample.
  - Evidence: `artifacts/feasibility/run-007a-llama3.2-3b-apple-strict/metrics.json`, `artifacts/feasibility/run-007b-llama3.2-3b-low-context/metrics.json`, `artifacts/feasibility/run-007c-llama3.2-3b-multilingual-evidence/metrics.json`, `artifacts/feasibility/run-007d-llama3.2-3b-recalibrated-v1/metrics.json`, `artifacts/feasibility/run-0084-llama3.2-3b-apple-guardrail-only/metrics.json`
- 2026-03-02: Frozen run artifact bundle created and deterministic rerun validated.
  - Evidence: `artifacts/feasibility/run-006-llama3.2-3b/dataset-manifest.json`, `artifacts/feasibility/run-006-llama3.2-3b/item-output-hashes.jsonl`, `artifacts/feasibility/run-006-llama3.2-3b/decision-log.md`
- 2026-03-02: Repository reset to classification-only validation scope.
  - Evidence: `config/feeds-v1.md`, `config/categories-v1.yaml`, `data/review/current/items.jsonl`

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update `docs/STATUS.md` in the same change.
