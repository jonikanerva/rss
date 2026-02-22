# Feasibility Spike Pre-Build Gate Check

Date: 2026-02-21
Owner: RPI Orchestrator
Scope: Go/No-Go decision for starting full macOS/Xcode scaffold.

## Decision

- Status: FAIL (default until evidence is attached)
- Readiness stance: Full scaffold is blocked until all hard pass criteria below pass in one frozen run.
- Highest-risk gate: Grouping overmerge (false merges damage trust fastest).

## Gate Intent

This gate validates feasibility for the hard MVP thesis before committing to production project structure.
No launch readiness is claimed here. This is a pre-build feasibility gate only.

## Hard Pass Criteria (All Required)

### C1 Chronology Integrity

- Metric: timeline inversion rate.
- Threshold: 0.0% (strictly no inversions).
- Metric: canonical timestamp coverage.
- Threshold: 100%.
- Metric: rerun order stability (same input, same ordered IDs).
- Threshold: 100%.
- Minimum sample: >= 2,000 items, >= 15 feeds, >= 14-day window.

### C2 Categorization Quality

- Metric: category coverage (model or fallback).
- Threshold: 100%.
- Metric: macro F1.
- Threshold: >= 0.82.
- Guardrail: per-category F1 >= 0.65 where support >= 20.
- Metric: fallback rate.
- Threshold: <= 0.25.
- Minimum sample: >= 600 labeled items, >= 10 categories, support >= 20/category.

### C3 Same-Story Grouping Quality

- Metric: group purity.
- Threshold: >= 0.82.
- Metric: overmerge rate.
- Threshold: <= 0.08.
- Metric: split rate.
- Threshold: <= 0.15.
- Minimum sample: >= 250 truth groups and >= 2,500 grouped items.

### C4 Human Trust Proxy

- Metric: first-pass correction rate.
- Threshold: <= 0.20.
- Definition: corrected_items / reviewed_items in same window.
- Minimum sample: >= 300 reviewed items across top categories.

### C5 Pipeline Feasibility

- Metric: pipeline completion rate (category + group + canonical timestamp present).
- Threshold: >= 99.0%.
- Metric: schema-valid output rate.
- Threshold: >= 99.5%.
- Metric: p95 offline processing time.
- Threshold: <= 5.0s/item on agreed test hardware profile.
- Minimum sample: same 2,000-item run as C1.

## GO / NO-GO Rule

- GO only if all C1-C5 thresholds pass, all minimum sample sizes are met, and all evidence artifacts are complete and reproducible.
- NO-GO if any threshold fails, any sample minimum is missed, or any required artifact is missing.

## Required Evidence Artifacts

- `artifacts/feasibility/<run-id>/dataset-manifest.json`
- `artifacts/feasibility/<run-id>/labels-taxonomy.csv`
- `artifacts/feasibility/<run-id>/labels-same-story.csv`
- `artifacts/feasibility/<run-id>/metrics.json`
- `artifacts/feasibility/<run-id>/chronology-report.json`
- `artifacts/feasibility/<run-id>/error-analysis.md`
- `artifacts/feasibility/<run-id>/dogfood-corrections.csv`
- `artifacts/feasibility/<run-id>/decision-log.md`

## Gate Execution Checklist

- [ ] Freeze one evaluation snapshot and record version metadata.
- [ ] Run chronology invariants and verify C1 thresholds.
- [ ] Run categorization evaluation and verify C2 thresholds.
- [ ] Run grouping evaluation and verify C3 thresholds.
- [ ] Compute correction rate and verify C4 threshold.
- [ ] Run pipeline feasibility metrics and verify C5 thresholds.
- [ ] Validate sample-size minimums before interpreting metrics.
- [ ] Attach reproducible command, commit SHA, and run timestamp.
- [ ] Record explicit GO/NO-GO with product + engineering signoff.

## Remediation Rules

If FAIL:

1. Fix the highest-risk failed metric first (default: overmerge).
2. Re-run on the same frozen snapshot to preserve comparability.
3. Update error analysis and decision log.
4. Keep status FAIL until all C1-C5 criteria pass in one run.

## Latest Evaluation (run-003)

- Run ID: `20260222-095207`
- Command:

```bash
swift run rss-spike benchmark \
  --dataset "data/eval/v0/items.jsonl" \
  --taxonomy-labels "data/eval/v0/labels-taxonomy.csv" \
  --story-labels "data/eval/v0/labels-same-story.csv" \
  --taxonomy-version "v1" \
  --guideline-version "v1" \
  --hardware-profile "macos-m1-8gb" \
  --output "artifacts/feasibility/run-003"
```

- Decision: **NO-GO**
- Decision source: `artifacts/feasibility/run-003/decision-log.md`

### Evidence links

- Manifest: `artifacts/feasibility/run-003/dataset-manifest.json`
- Labels taxonomy: `artifacts/feasibility/run-003/labels-taxonomy.csv`
- Labels same-story: `artifacts/feasibility/run-003/labels-same-story.csv`
- Metrics: `artifacts/feasibility/run-003/metrics.json`
- Chronology: `artifacts/feasibility/run-003/chronology-report.json`
- Error analysis: `artifacts/feasibility/run-003/error-analysis.md`
- Dogfood corrections: `artifacts/feasibility/run-003/dogfood-corrections.csv`
- Decision log: `artifacts/feasibility/run-003/decision-log.md`

### Threshold status snapshot

- C1 Chronology: metric values pass, **sample minimum fails**.
- C2 Categorization: **insufficient evidence** (F1 metrics not present, sample minimum fails).
- C3 Grouping: metric values pass, **sample minimum fails**.
- C4 Human trust proxy: **fails** (no reviewed sample yet).
- C5 Pipeline feasibility: metric values pass, **sample minimum tied to C1 fails**.
