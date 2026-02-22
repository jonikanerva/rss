# No-Build Quality Gate: Categorization and Grouping

Date: 2026-02-21
Owner: Quality Gatekeeper (agent)
Scope: Gate definition for production readiness without requiring a code build/deploy.

## Decision

- Status: FAIL
- Release readiness stance: Not release-ready until all threshold checks are met with current-window evidence.
- Highest-risk gate: G2 Evidence and traceability (metrics can be claimed without reproducible sources unless strict evidence links are provided).
- Minimum remediation set for PASS:
  1. Provide evidence links/snapshots for every metric listed in this gate from the same evaluation window.
  2. Meet all threshold values in the Hard Pass Criteria section.
  3. Confirm policy/security checks for data handling and PII redaction in evaluation artifacts.
  4. Record human owner signoff with timestamp.

## Gate Intent (No-Build)

This gate verifies model/output quality and operational reliability using offline labeled evaluation + production telemetry only. No build, test run, or deployment step is required to execute this gate.

## Hard Pass Criteria (All Required)

### 1) Categorization Quality

- Metric: Macro F1 on labeled holdout set.
- Threshold: >= 0.92
- Guardrail: Per-category F1 >= 0.85 for every category with support >= 100.
- Minimum sample: >= 10,000 labeled items spanning >= 20 categories.

### 2) Grouping Quality

- Group purity: >= 0.90
- Split rate (single true group split across predicted groups): <= 0.05
- Overmerge rate (distinct true groups merged): <= 0.03
- Minimum sample: >= 2,000 groups and >= 20,000 grouped items.

### 3) Latency

- P95 end-to-end latency: <= 450 ms
- P99 end-to-end latency: <= 900 ms
- Window: rolling 7 days, production telemetry only.
- Minimum volume: >= 50,000 requests in window.

### 4) Correction Rate

- Metric: Human correction rate after first-pass output.
- Threshold: <= 0.08
- Definition: corrected_items / total_items reviewed by humans in same window.
- Minimum sample: >= 5,000 reviewed items.

### 5) Reliability

- Successful request rate: >= 99.5%
- 5xx/system error rate: <= 0.5%
- Timeout rate: <= 0.2%
- Data completeness rate (non-empty, schema-valid output): >= 99.7%
- Window: rolling 7 days.

## Quality Gate Mapping

### G1: Artifact completeness

PASS requires:
- This gate document completed with all thresholds and definitions.
- Single evaluation window specified and used consistently.
- Named owner and decision timestamp.

### G2: Evidence and traceability

PASS requires:
- One evidence source per metric (dashboard link, query ID, or attached CSV report).
- Timestamped snapshots retained for audit.
- Reproducible query/filter definitions included.

### G3: Security and policy checks

PASS requires:
- Evaluation datasets exclude or redact sensitive identifiers.
- Access to raw evaluation artifacts restricted to approved roles.
- Any policy exceptions documented and approved.

### G4: Cross-artifact consistency

PASS requires:
- Metric definitions here match definitions in dashboards/reports.
- Numerator/denominator consistency across correction and reliability metrics.
- Same window boundaries across all reported values.

### G5: Human approval checkpoint

PASS requires:
- Product owner signoff.
- Engineering owner signoff.
- Decision logged as PASS with date/time and approver names.

## Gate Execution Checklist

- [ ] Collect labeled-eval report for categorization/grouping metrics.
- [ ] Export rolling 7-day telemetry for latency/reliability.
- [ ] Compute correction rate from review workflow data.
- [ ] Validate sample-size minimums.
- [ ] Validate all hard thresholds.
- [ ] Confirm policy/security checks.
- [ ] Obtain owner signoff.
- [ ] Record PASS/FAIL decision and archive evidence links.

## Remediation Items (Exact)

If any threshold fails, remediation is mandatory before PASS:

1. Categorization F1 below threshold
   - Increase labeled error analysis coverage to top 5 failing categories.
   - Implement category-specific rules/model tuning.
   - Re-run labeled holdout evaluation with unchanged sampling protocol.

2. Group purity below threshold OR split/overmerge above threshold
   - Add merge/split confusion audit for top 100 largest groups.
   - Adjust grouping similarity thresholds and conflict resolution logic.
   - Recompute purity, split rate, and overmerge rate on same benchmark set.

3. Latency above threshold
   - Profile top 3 slowest pipeline stages by p95 contribution.
   - Apply caching/batching/parallelization where safe.
   - Re-measure p95/p99 over at least 24h and then full 7-day window.

4. Correction rate above threshold
   - Bucket correction reasons and remove top 2 systemic causes.
   - Add targeted acceptance checks for corrected patterns.
   - Recompute correction rate after at least 5,000 reviewed items.

5. Reliability below threshold
   - Classify failure modes (5xx, timeout, invalid schema) and fix top contributors.
   - Add defensive retries/timeouts/fallbacks with idempotency safety.
   - Re-measure success/error/timeout/completeness in full 7-day window.

## Evidence Register (Fill Before Gate Decision)

- Categorization report: <link>
- Grouping report: <link>
- Latency dashboard/query: <link>
- Correction-rate source: <link>
- Reliability dashboard/query: <link>
- Security/policy validation note: <link>
- Product signoff record: <link>
- Engineering signoff record: <link>
