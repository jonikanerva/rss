# Feeder — Project Rules

## Project Overview

macOS RSS reader app: SwiftUI + SwiftData + Apple Foundation Models. Feedbin API sync, on-device classification, same-story grouping. Native Xcode project: `Feeder.xcodeproj`.

## Language Policy

- All project artifacts in **English**: code, comments, commits, branch names, PR titles, variable names.
- User communication in **Finnish**.

## Verification

Run before every commit and PR — all must pass, no exceptions:

```bash
make test-all
```

This runs: build (zero warnings) → unit tests → UI tests. Use `make help` for all available targets.

## Swift 6 Strict Concurrency (Non-Negotiable)

Swift 6 language mode, strict concurrency complete, default actor isolation MainActor. Zero warnings, zero errors. Full spec: `docs/swift-code-rules.md`. Design principles: `docs/app-rules.md`.

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

## Code Standards

- **Strong Swift**: no `@unchecked Sendable`, no `nonisolated(unsafe)`. Every type properly isolated.
- **Pure functions**: business logic as pure functions, side effects only at I/O boundaries.
- **Value types**: prefer `struct` and `enum`. Use `class` only when required.
- **DRY**: if logic is similar to existing code, refactor to reuse. Never copy-paste.
- **Single-purpose functions**: each function does one thing.
- **Naming**: descriptive, intention-revealing, English.
- **Minimal scoped changes**: change only what is necessary. No unrelated refactors during fixes.

## Git Workflow

- Use `/implement <task>` for the full branch → implement → test → PR workflow.
- Every feature gets its own branch. Branch from `main`, PR back to `main`.
- **NEVER** commit or push directly to `main`.
- **NEVER** force push (`--force` or `--force-with-lease`).
- Conventional Commits: `<type>(<scope>): <summary>`
- Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `chore/<topic>`
- Commits must be complete logical units — one logical change per commit.
- PRs are merged with merge commit, not squash. Always delete the branch after merge.
- **PR as audit trail**: the PR description must fully describe what and why. Design decisions, trade-offs, and compromises documented in PR comments.
- After PR is merged: delete the local and remote feature branch, switch back to `main`, and pull.

## Safeguards

- **NEVER** read `.env` files (`.env`, `.env.*`, `.env.local`).
- **NEVER** commit secrets, credentials, API keys, or tokens.
- **NEVER** run `rm -rf` on project directories.
- **NEVER** merge a PR without all verification passing.

## Planning

Use Claude Code's built-in `/plan` mode for any non-trivial work. Before implementation, research the codebase and relevant documentation as part of planning — no separate research phase needed.

## Code Review

Use `/codereview` after creating a PR. The skill handles: isolated subagent review → audit trail comment → fix → re-review.

## SwiftData Schema Versioning

Bump `currentSchemaVersion` in `FeederApp.swift` when schema changes. Database auto-resets on version mismatch. Never write migrations.

## Status Tracking

`docs/next-actions.md` tracks the active work queue. Update on meaningful changes.

## Decision Rights

- **Auto-allow**: read-only commands, local builds/tests, feature branch ops, PR creation.
- **Ask first**: writes outside feature branch, edits to `docs/vision/VISION.md`, secrets/auth/billing.
- **Never**: force push, `rm -rf`, push to main, bypass hooks, weaken concurrency settings.
