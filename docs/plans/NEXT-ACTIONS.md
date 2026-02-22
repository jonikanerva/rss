# Next Actions (Execution Queue)

Date: 2026-02-22
Owner: Repository Owner + Agent
Status: Active

## Rules

- Keep exactly 1 item `In progress`.
- Keep maximum 3 active items total (`In progress` + `Ready`).
- Every item includes owner, acceptance check, and target checkpoint.
- Move completed items to the history section with date and evidence link.

## Active queue

1. [In progress] Human review of 303-item dogfood review sheet
   - Owner: Product owner
   - Acceptance check: all 303 rows in `data/eval/dogfood-v1/review-sheet.csv` have `categories_correct`, `correct_categories`, `grouping_correct` filled in.
   - Target checkpoint: before correction rate computation
   - How to do it: open `data/eval/dogfood-v1/review-sheet.csv` in a spreadsheet. For each row, mark whether the `pipeline_categories` are correct, provide corrections if not, and note grouping accuracy. Available categories: `apple`, `playstation 5`, `video games`, `ai`, `science`, `entertainment`, `technology`, `unsorted`.

2. [Ready] Compute correction rate and update gate evidence
   - Owner: Agent
   - Acceptance check: `dogfood-corrections.csv` contains computed correction rate from real reviewed items; gate document updated with real C4 evidence.
   - Target checkpoint: after item 1

3. [Ready] Owner signoff on gate decision (GO/NO-GO)
   - Owner: Product owner + Engineering owner
   - Acceptance check: explicit signoff recorded in gate document with timestamp.
   - Target checkpoint: after item 2

## Completed history

- 2026-02-22: Real RSS data pipeline with 303 items from 8 feeds, multi-label categorization.
  - Evidence: `data/eval/dogfood-v1/items.jsonl`, `data/eval/dogfood-v1/review-sheet.csv`, `artifacts/feasibility/dogfood-run-002/metrics.json`
  - Branch: `feat/dogfood-real-data` (2 commits, not yet pushed/merged)
- 2026-02-22: Multi-label categorization refactor (7 user-defined categories + unsorted fallback).
  - Evidence: `Sources/RSSSpikeCore/BaselinePipeline.swift`, `Sources/rss-spike/rss_spike.swift`, all 13 tests passing
- 2026-02-22: Expanded frozen evaluation dataset (`v1`) to feasibility minimum sample sizes.
  - Evidence: `data/eval/v1/items.jsonl`, `data/eval/v1/labels-taxonomy.csv`, `data/eval/v1/labels-same-story.csv`, `artifacts/feasibility/run-005/metrics.json`
- 2026-02-22: Categorization quality metrics (macro F1 + per-category) added to benchmark output.
  - Evidence: `Sources/RSSSpikeCore/CategorizationQuality.swift`, `Tests/RSSSpikeCoreTests/CategorizationQualityMetricsTests.swift`, `artifacts/feasibility/run-005/metrics.json`
- 2026-02-22: Reproducible feasibility run completed (`run-005`) with updated gate linkage.
  - Evidence: `artifacts/feasibility/run-005/`, `docs/quality-gates/2026-02-21-feasibility-spike-prebuild-gate-check.md`
- 2026-02-22: Grouping quality metrics integrated into benchmark output.
  - Evidence: `Sources/RSSSpikeCore/GroupingQuality.swift`, `Tests/RSSSpikeCoreTests/GroupingQualityMetricsTests.swift`, `artifacts/feasibility/run-002/metrics.json`
- 2026-02-22: Reproducible feasibility run completed (`run-003`) with artifact bundle and NO-GO decision log.
  - Evidence: `artifacts/feasibility/run-003/`, `docs/quality-gates/2026-02-21-feasibility-spike-prebuild-gate-check.md`
- 2026-02-22: Worktree-per-session default documented in operating model.
  - Evidence: `docs/operating-model/handoff-protocol.md`, `docs/operating-model/cadence.md`
- 2026-02-22: Multi-agent git isolation research drafted.
  - Evidence: `docs/research/2026-02-22-multi-agent-git-isolation-options.md`

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update `docs/STATUS.md` in the same change.
