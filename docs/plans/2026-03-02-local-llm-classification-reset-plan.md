# Plan: Local LLM Classification Reset

Date: 2026-03-02
Owner: Repository Owner + Agent
Status: Active
Derived from: `docs/research/2026-03-02-local-llm-classification-reset.md`

## Scope and goals

- Validate local LLM category assignment quality against reduced taxonomy.
- Use only real Feedbin article queue for manual correction sampling.
- Produce reproducible run artifacts for GO/NO-GO decision.

## Milestones and dependencies

1. Freeze source + taxonomy configs
   - `config/feedbin-feeds-v1.json`
   - `config/feedbin-fetch-profile-v1.json`
   - `config/categories-v1.yaml`
   - `config/taxonomy-manifest-v1.json`
2. Build review queue
   - `data/review/current/items.jsonl`
3. Run local benchmark and collect artifacts
4. Complete >=300 manual reviews and compute correction rate
5. Record gate decision and owner signoff

## Risks and mitigations

- Source drift: regenerate queue only via frozen profile file.
- Label ambiguity: keep taxonomy small and definitions explicit.
- Review quality drift: require correction reasons on edited rows.

## Acceptance criteria

- Queue contains real Feedbin items and no synthetic benchmark rows.
- Every item gets at least one category label (`unsorted` fallback allowed).
- Deterministic rerun evidence is recorded for the same snapshot.
- `dogfood-corrections.csv` has >=300 reviewed rows.

## Quality gate checklist

- [ ] Config files frozen
- [ ] Queue generated from Feedbin profile
- [ ] Local LLM benchmark run completed
- [ ] Manual review threshold reached
- [ ] Gate decision documented
