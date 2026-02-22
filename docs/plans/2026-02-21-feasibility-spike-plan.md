# Feasibility Spike Plan (Pre-Scaffold)

Date: 2026-02-21
Owner: RPI Orchestrator
Status: Ready for execution

## Scope and goals

- Prove feasibility of always-on categorization + always-on same-story grouping before full macOS/Xcode scaffold.
- Preserve strict chronology invariant in data and UI behavior.
- Produce reproducible evidence artifacts for pre-build gate decision.

## Milestones and dependencies (10-day target)

1. M1: Core contracts and chronology invariants (Day 1-2)
   - Define canonical item schema (`category`, `group`, `canonical_timestamp`).
   - Implement deterministic ordering invariants.
   - Dependency: none.

2. M2: Baseline pipeline implementation (Day 3-5)
   - Ingest -> normalize -> categorize (with fallback) -> group -> ordered output.
   - Ensure idempotent replay behavior.
   - Dependency: M1.

3. M3: CLI benchmark + metrics export (Day 6-8)
   - Add benchmark runner and machine-readable reports.
   - Emit chronology, quality, latency, and completion metrics.
   - Dependency: M2.

4. M4: Minimal SwiftUI proof shell (Day 6-9, parallel)
   - Render ordered grouped timeline from pipeline output.
   - Validate group expand/collapse does not reorder adjacent timeline items.
   - Dependency: M2.

5. M5: Go/No-Go checkpoint (Day 10)
   - Evaluate against `docs/quality-gates/2026-02-21-feasibility-spike-prebuild-gate-check.md`.
   - Record decision in artifact bundle.
   - Dependency: M3 and M4.

Critical path: M1 -> M2 -> M3 -> M5.

## Benchmark command skeleton

Use this shape for reproducible feasibility runs:

```bash
swift run rss-spike benchmark \
  --dataset "data/eval/v0/items.jsonl" \
  --taxonomy-labels "data/eval/v0/labels-taxonomy.csv" \
  --story-labels "data/eval/v0/labels-same-story.csv" \
  --taxonomy-version "v1" \
  --guideline-version "v1" \
  --hardware-profile "macos-m1-8gb" \
  --output "artifacts/feasibility/<run-id>"
```

Expected output bundle:

- `artifacts/feasibility/<run-id>/dataset-manifest.json`
- `artifacts/feasibility/<run-id>/metrics.json`
- `artifacts/feasibility/<run-id>/chronology-report.json`
- `artifacts/feasibility/<run-id>/error-analysis.md`
- `artifacts/feasibility/<run-id>/decision-log.md`

## Risks and mitigations

1. Small dataset inflates quality metrics.
   - Mitigation: enforce sample minimums in gate check before decision.

2. Grouping false merges reduce trust.
   - Mitigation: prioritize overmerge remediation first; rerun same frozen snapshot.

3. Latency variability across Macs masks true feasibility.
   - Mitigation: lock hardware profile for gate run and report it in manifest.

## Acceptance criteria for starting full scaffold

- All C1-C5 criteria pass in one frozen run.
- All required artifacts are present and reproducible.
- Product + engineering signoff recorded in decision log.
