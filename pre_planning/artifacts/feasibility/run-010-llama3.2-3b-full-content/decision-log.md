# Decision Log: run-010-llama3.2-3b-full-content

Date: 2026-03-03T16:32:02+00:00
Status: Candidate (frozen)

## What changed from run-009

- **Queue**: Replaced excerpt-heavy queue (102 items, median body 298 chars, 51% excerpt-only) with full-content extracted queue (106 items, median body 1,473 chars, 0 excerpt-only).
- **Context window**: Increased `num_ctx` from 1024 to 4096. The old 1024 window truncated prompts for 25% of items, causing the model to never see the category definitions and defaulting to `other`.
- **`num_predict`**: Increased from 180 to 200 for slightly more output room.
- **Content extraction**: 54/106 items use Feedbin's `extracted_content_url` (Mercury Parser) for full article content. 52/106 had sufficient feed content already.

## Prompt design

- Same fully generic prompt as run-009. No category-specific logic.
- Categories passed as user-defined label + description pairs.
- Key instruction: "Only assign a category when the article content provides clear evidence for it."
- No post-processing guardrails, token lists, or policy overrides.

## Model and settings

- Model: `llama3.2:3b`
- Inference: temperature=0, top_k=1, seed=0, num_predict=200, num_ctx=4096

## Key metrics comparison

| Metric | run-009 (excerpt, 1024 ctx) | run-010 (full content, 4096 ctx) |
|--------|----------------------------|----------------------------------|
| Total items | 102 | 106 |
| Fallback rate | 22.5% | 24.5% |
| Apple labels | 15 | 18 |
| Gaming labels | 9 | 15 |
| World labels | 23 | 19 |
| Technology labels | 54 | 62 |
| AI labels | 15 | 18 |

Note: Direct metric comparison is limited because the queues contain different articles (different Feedbin fetch windows).

## Context window fix evidence

With `num_ctx=1024` on the full-content queue, fallback rate was 47.2% and Apple articles with "Apple" in the title were classified as `other`. After increasing to 4096, all Apple-titled articles correctly received `apple, technology` labels.

## Produced artifacts

- `dataset-manifest.json`
- `runtime-manifest.json`
- `metrics.json`
- `predictions.jsonl`
- `item-output-hashes.jsonl`
- `dogfood-corrections.csv` (header initialized)

## Determinism check

- Compared against: `run-010-llama3.2-3b-full-content-rerun`
- Compared items: 106
- Hash matches: 106
- Hash match rate: 1.0000
- Checked at: 2026-03-03T16:50:00+00:00

## Remaining checks

- Complete manual dogfood review to >=300 rows and record correction rate.
- Compute micro/macro F1, Jaccard against gate thresholds.
- Record final GO/NO-GO owner signoff in gate doc.
