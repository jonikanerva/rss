# Decision Log: run-013-apple-fm-english-only

Date: 2026-03-04
Owner: Repository Owner + Agent
Status: Reviewed — DOES NOT PASS gate (correction rate too high)

## Run summary

- **Model**: Apple Foundation Models (default, macOS 26.3)
- **Greedy sampling**: Yes (deterministic)
- **Language detection**: NaturalLanguage framework, skip non-English
- **Body truncation**: 8K chars max
- **Total items**: 106
- **English items classified**: 75
- **Non-English skipped**: 31 (30 Finnish, 1 Indonesian)
- **Errors**: 0
- **Fallback rate (overall)**: 35.8% (38/106) — includes 31 language-skipped items
- **Fallback rate (English only)**: 9.3% (7/75)

## Dogfood review results

- **Total reviewed**: 106 (all items)
- **Total corrected**: 29
- **Overall correction rate**: 27.4% — **FAILS gate threshold (≤20% required)**
- **English-only correction rate**: 38.7% (29/75) — **FAILS gate threshold**
- **Finnish items correction rate**: 0% (0/31) — all accepted as "other"

## Correction pattern analysis

The dominant correction patterns reveal systematic weaknesses:

| Pattern | Count | Description |
|---------|-------|-------------|
| missing:technology | 10 | Under-assigns broad "technology" label alongside specific categories |
| extra:other | 8 | Over-uses "other" as secondary label instead of a real category |
| missing:world | 7 | Misses "world" dimension on policy/government + tech articles |
| missing:gaming_industry | 5 | Doesn't distinguish gaming industry news (layoffs, closures) |
| missing:ai | 5 | Misses "ai" on articles where AI companies are in policy/world context |
| missing:apple | 4 | Misses "apple" on some Apple product articles |
| extra:world | 2 | Incorrectly assigns "world" to non-world articles |
| missing:gaming | 1 | Misses gaming label |
| extra:ai | 1 | Incorrectly assigns "ai" to non-AI article (Clair Obscur game) |

## Key findings

1. **Apple FM tends toward single-label classification.** It assigns avg 1.37 labels/item vs Ollama's 1.76. This is the root cause of most corrections — it picks the most specific label but misses the broad category.

2. **The "technology" under-assignment is the biggest gap.** Apple FM assigned "technology" only 24 times vs Ollama's 62. Many Apple product articles got "apple" but not "technology", and many tech articles got a specific label but not the broad "technology" umbrella.

3. **"other" is over-used as a secondary label.** When Apple FM does assign 2 labels, the second is often "other" instead of a meaningful category. This inflates the fallback count.

4. **Cross-domain articles are poorly handled.** Articles about AI companies in government/policy contexts (OpenAI + DOD, Anthropic + government) get only one dimension (either "ai" or "world") but not both.

5. **Gaming industry news is not distinguished.** Layoffs, studio closures, and insolvency news from gaming sources gets "other" instead of "gaming_industry".

## Comparison with Ollama run-010

| Metric | Apple FM (run-013) | Ollama (run-010) |
|--------|-------------------|------------------|
| Fallback rate (overall) | 35.8% | 24.5% |
| Fallback rate (English) | 9.3% | N/A (classified all) |
| Avg labels/item | 1.37 | 1.76 |
| technology count | 24 | 62 |
| apple count | 10 | 18 |
| Speed (median) | ~1,062ms | ~12,000ms |
| Errors | 0 | 0 |

## Recommendation

**Run-013 does not pass the gate.** The prompt needs tuning to:
1. Encourage multi-label assignment (especially broad categories like "technology")
2. Reduce "other" as a secondary label
3. Better handle cross-domain articles (ai + world, gaming + gaming_industry)

**Next step**: Create run-014 with an improved prompt that explicitly instructs multi-label assignment, then re-review.

## Evidence artifacts

- `predictions.jsonl` — 106 predictions
- `metrics.json` — run metrics
- `dogfood-corrections.csv` — 106 reviewed rows, 29 corrections
