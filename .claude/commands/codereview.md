Review all changes on the current branch against `main`. **This command runs as an isolated subagent** — do not rely on any prior conversation context. Derive all understanding from the PR diff and description only.

## Prerequisites

- A PR must exist for the current branch. If not, stop and say: create the PR first.
- Run `bash .claude/scripts/use-github-app-auth.sh` before posting comments.
- Read the PR description and full diff (`git diff main...HEAD`) as your sole inputs.

## Review checklist

Analyze the full diff (`git diff main...HEAD`) and evaluate:

1. **Scope verification** — does the diff match the PR description? Are there undocumented changes — especially removals, renames, or architectural shifts? Cross-check against any research/plan artifacts included in the PR branch (`docs/research/`, `docs/plans/`).
2. **Security analysis** — injection risks, credential exposure, unsafe data handling, OWASP top 10.
3. **Threat modeling** — what could go wrong in production? Data corruption, race conditions, crashes.
4. **Code style** — compliance with code style section in `docs/swift-concurrency-rules.md`.
5. **Swift best practices** — modern Swift 6 patterns, proper actor isolation, correct Sendable conformance.
6. **Architecture compliance** — two-layer rule, no computation in views, predicates pushed to @Query.

## Output

Post a single PR comment (`gh pr comment`) with:

- **PASS** or **FAIL** verdict
- Per-checklist findings (or "No issues" if clean)
- For FAIL: specific file, line, and description for each issue

Every review round gets its own comment — including failed reviews — so there is a permanent audit trail in GitHub.

## If issues are found

Fix them, commit, push, and run `/codereview` again. Repeat until PASS.
