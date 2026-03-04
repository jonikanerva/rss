# Gate Check: Local LLM Classification Reset

Date: 2026-03-02
Updated: 2026-03-04
Owner: Repository Owner + Agent
Status: **GO — signed off 2026-03-04**

## Decision policy

- GO only if all checks below pass in one frozen run.
- NO-GO if any check fails or required evidence is missing.

## Threshold adjustments (2026-03-04)

Original thresholds were set before the queue size and language composition were known.
Adjustments approved by product owner on 2026-03-04:

| Threshold | Original | Adjusted | Rationale |
|-----------|----------|----------|-----------|
| Reviewed rows | ≥300 | ≥106 (all available) | Queue contains exactly 106 real Feedbin items. All were reviewed. |
| F1 / Jaccard | Required | Removed | Correction rate is the direct human trust signal; F1 is a derived proxy that adds complexity without changing the decision. |
| Fallback rate | ≤0.20 | Removed | 31/36 "other" items are Finnish articles correctly auto-tagged via language detection. English-only fallback is 5/75 = 6.7%. Correction rate already captures real quality. |
| Deterministic rerun | Hash comparison required | Greedy sampling flag sufficient | Apple FM greedy sampling (`GenerationOptions(sampling: .greedy)`) produces deterministic output per OS version. Rerun hash comparison deferred to production test suite. |
| Evidence artifacts | 6 files required | 4 files required | `runtime-manifest.json`, `dataset-manifest.json`, and `item-output-hashes.jsonl` removed. `metrics.json` captures run config. `decision-log.md` captures runtime details. |

## Required checks

1. Coverage and validity
   - 100% of items receive at least one allowed label.
   - Schema-valid output rate >= 99.5%.

2. Determinism
   - Greedy sampling enabled and recorded in metrics.
   - Runtime/model details documented in decision log.

3. Human trust proxy
   - `dogfood-corrections.csv` has ≥106 reviewed rows (all available items).
   - First-pass correction rate ≤ 0.20.

## Evaluation: run-017-apple-fm-tighter-descriptions

| Check | Threshold | Actual | Result |
|-------|-----------|--------|--------|
| Coverage | 100% items get ≥1 label | 106/106 (100%) | ✅ PASS |
| Schema validity | ≥99.5% | 106/106 (100%), 0 errors | ✅ PASS |
| Greedy sampling | Enabled | `"greedy": true` in metrics.json | ✅ PASS |
| Runtime documented | Decision log present | decision-log.md: Apple FM default, macOS 26.3, NaturalLanguage detection, 8K body truncation | ✅ PASS |
| Reviewed rows | ≥106 | 106 reviewed | ✅ PASS |
| Correction rate | ≤0.20 | 20/106 = 18.9% | ✅ PASS |

**All checks pass. Recommendation: GO.**

## Required evidence artifacts

- `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/metrics.json` ✅
- `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/predictions.jsonl` ✅
- `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/dogfood-corrections.csv` ✅
- `artifacts/feasibility/run-017-apple-fm-tighter-descriptions/decision-log.md` ✅

## Key findings for next phase

1. **Category descriptions are the primary quality lever.** The system prompt must remain generic. Quality improvements come from user-editable category names + descriptions. This validates the product design.
2. **Apple Foundation Models are the production target.** 10x faster than Ollama, zero app size impact, native Swift integration, `@Generable` eliminates JSON parsing issues.
3. **English-only MVP is confirmed.** Finnish articles (28% of queue) are correctly detected and skipped. Translation is post-MVP.
4. **Known remaining gaps** (addressable post-gate):
   - "other" still combines with real labels (5/20 corrections) — post-processing rule candidate.
   - `gaming_industry` under-used for layoff articles (4/20 corrections) — description refinement.
   - Cross-domain AI+government labeling (6/20 corrections) — description refinement.

## Owner signoff

- Product owner signoff: **GO**
- Engineering owner signoff: **GO**
- Signoff timestamp: 2026-03-04
- Notes: Owner confirmed gate pass. Pragmatic thresholds accepted. Advance to R5.
