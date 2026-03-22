# Feeder — Project Rules

## Session Start

1. Read `docs/STATUS.md` for current project state.
2. Read `docs/plans/NEXT-ACTIONS.md` for active work queue.

## Prompt Analysis Protocol (Every Request)

Before acting on any user request, classify and propose an approach:

**TRIVIAL** (typo, config tweak, rename, single-line fix):
→ State what you'll change. Implement on user approval.

**SMALL** (bug fix, minor UI change, localized refactor):
→ Propose approach. Ask: "This looks small — OK to skip research/plan and implement directly?"
→ Implement on approval.

**MEANINGFUL** (new feature, architecture change, multi-file refactor, anything uncertain):
→ State: "This needs the full pipeline: research → plan → implement."
→ Create worktree + feature branch **immediately** (before research), so all artifacts land in the same branch.
→ Run each phase. Pause for human approval at phase transitions:
  1. **Research** → commit dossier to branch → present findings → user approves
  2. **Plan** → commit plan to branch → present plan → user approves
  3. **Implement** → code autonomously, verify build + tests at each milestone, commit at checkpoints
  4. **Exit worktree** → merge worktree changes back to the feature branch in the main repo, remove worktree
  5. **Push & open PR** → update STATUS.md/NEXT-ACTIONS.md, push branch, open PR (draft OK)
  6. **Code review** → spawn review subagent against the PR (see below) → fix issues → repeat until PASS
  7. **Human review** → present to user for testing in Xcode and final approval before merge

If uncertain about classification, default to MEANINGFUL.

### Worktree Exit (Before PR)

After implementation and build verification pass, **exit the worktree before creating the PR**:
1. Commit all remaining changes in the worktree.
2. Exit the worktree (merges changes to the feature branch in the main repo).
3. The user can now open the feature branch in Xcode for testing.
4. All subsequent work (PR creation, code review fixes) happens in the main repo, NOT in a worktree.

### Automated Code Review (After PR Creation — NOT Before)

**CRITICAL: The PR must exist before code review starts.** The review agent writes its analysis as PR comments, which requires a live PR.

After the PR is created, spawn a code review subagent that reviews ALL changes on the branch (diff against `main`). The review must cover:

1. **Security analysis** — injection risks, credential exposure, unsafe data handling, OWASP top 10.
2. **Threat modeling** — what could go wrong with this code in production? Data corruption, race conditions, crashes.
3. **Code style** — compliance with code style section in `docs/swift-concurrency-rules.md`.
4. **Swift best practices** — modern Swift 6 patterns, proper actor isolation, correct Sendable conformance.
5. **Architecture compliance** — two-layer rule, no computation in views, predicates pushed to @Query.

After each review round, post the full review summary and findings as a comment on the PR (`gh pr comment`) so there is a permanent audit trail in GitHub — including failed reviews with the issues that need fixing.

If the review finds issues: fix them, commit, push, and run the review again. Repeat until the review passes clean. Only then present to the user for final human review and merge approval.

### Artifacts

| Type | Location |
|------|----------|
| Research | `docs/research/YYYY-MM-DD-<topic>.md` |
| Plans | `docs/plans/YYYY-MM-DD-<topic>-plan.md` |
| Execution logs | `docs/plans/YYYY-MM-DD-<topic>-execution-log.md` |
| Quality gates | `docs/quality-gates/YYYY-MM-DD-<topic>-gate.md` |

### Status Tracking

Update `docs/STATUS.md` and `docs/plans/NEXT-ACTIONS.md` on meaningful changes.

## Agent Dispatch

For research and analysis, spawn focused subagents in parallel when multiple domains apply:

| Context | Subagent role |
|---------|--------------|
| Problem discovery, evidence gathering | Research analyst |
| Vision, scope, product direction | Product strategist |
| Milestones, sequencing, dependencies | Roadmap planner |
| Quality checks, release readiness | Quality gatekeeper |

## Swift 6 Strict Concurrency (Non-Negotiable)

Swift 6 language mode, strict concurrency complete, default actor isolation MainActor. Zero warnings, zero errors. Full spec: `docs/swift-concurrency-rules.md`.

### Two-Layer Architecture

- **Data layer** (background): `DataWriter` (`@ModelActor`), `FeedbinClient` (`actor`), pure helpers (`nonisolated`). All writes, network, computation here. Pre-compute display fields at write time.
- **UI layer** (MainActor, read-only): SwiftUI views read via `@Query` with SQLite predicates. `SyncEngine`/`ClassificationEngine` are `@Observable` for progress display only — zero `ModelContext`, delegate to `DataWriter`.

### Key Rules

- No `ModelContext` on MainActor for writes — all writes through `DataWriter`.
- No Swift filtering of `@Query` results — push predicates to `@Query`.
- No expensive computation during rendering.
- DTOs crossing actors: `nonisolated struct` + `Sendable`.
- `@Model` objects never cross actor boundaries — use `PersistentIdentifier`.
- `DataWriter` must init on a background thread.

### Prohibited Patterns

No `DispatchQueue`/GCD/`NSLock`/semaphores/`OperationQueue`. No completion handlers. No `Combine` for async. No `withCheckedContinuation`. No `Timer.scheduledTimer` — use `Task.sleep(for:)`. No `[weak self]` in Task closures.

### Build Verification

```bash
xcodebuild -project Feeder.xcodeproj -scheme Feeder -configuration Debug build 2>&1 | grep -E "(error:|warning:)"
# Must produce zero output
```

## Language

- All code, comments, documentation, commit messages, PR titles/descriptions, and branch names must be in **English**.
- Respond to the user in **Finnish** regardless of the language they use.

## Git Conventions

- Conventional Commits: `<type>(<scope>): <summary>`
- Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `chore/<topic>`
- One worktree per session, one task branch, one PR scope.
- PRs target `main` only. Never push directly to `main`.
- Run `bash .claude/scripts/use-github-app-auth.sh` before push/PR.
- After PR is merged: delete the local and remote feature branch, switch back to `main`, and pull.

## Decision Rights

- **Auto-allow**: read-only commands, local builds/tests, feature branch ops, PR creation.
- **Ask first**: writes outside feature branch, edits to `docs/vision/VISION.md`, secrets/auth/billing.
- **Never**: force push, `rm -rf`, push to main, bypass hooks, weaken concurrency settings.

## SwiftData Schema Versioning

Bump `currentSchemaVersion` in `FeederApp.swift` when schema changes. Database auto-resets on version mismatch. Never write migrations.
