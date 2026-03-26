---
name: research
description: Act as a research analyst — investigate a topic and produce a dossier
user-invocable: true
---

Act as a **research analyst**. Investigate: $ARGUMENTS

If no worktree/feature branch exists yet, create one now (all pipeline artifacts must live in the same branch as the implementation).

1. Search the web, explore the codebase, and read relevant documentation.
2. Write dossier to `docs/research/YYYY-MM-DD-<topic>.md` (use today's date).
3. Commit the dossier to the feature branch.

## Required sections

1. **Problem** — what exactly are we solving?
2. **Constraints** — known limits, assumptions, dependencies.
3. **Alternatives** — at least 2-3 options with pros/cons.
4. **Evidence** — data, source links, benchmarks, prior art.
5. **Unknowns** — what we don't know yet. Flag the single biggest risk.
6. **Recommendation** — is evidence sufficient to plan, or do we need more research?

Do NOT produce implementation plans — research only.
