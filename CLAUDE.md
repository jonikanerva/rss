# Feeder — Project Rules

## Startup Checklist

At the start of every session:
1. Read `docs/STATUS.md` for current project state.
2. Read the full `docs/operating-model/` folder before any implementation.

## RPI Workflow (Mandatory)

Enforce **Research → Plan → Implement** for every meaningful change.

- Research is mandatory before planning.
- Planning is mandatory before implementation.
- Use slash commands: `/research`, `/plan`, `/implement`, `/gate-check`, `/vision`, `/roadmap`.
- Do not produce planning outputs unless a research artifact exists (or user explicitly requests exploratory-only).
- Do not implement unless research and plan artifacts exist (or user explicitly requests a draft).
- Call out missing artifacts and suggest the exact next command.

### Artifact locations

| Type | Directory |
|------|-----------|
| Research dossiers | `docs/research/` |
| Plans | `docs/plans/` |
| Quality gate results | `docs/quality-gates/` |

### Status tracking

Update `docs/STATUS.md` and `docs/plans/NEXT-ACTIONS.md` on meaningful changes.

## Agent Dispatch Guidelines

When a user prompt matches a specialist domain, use the **Agent tool** to spawn a focused subagent. Dispatch rules:

| Prompt context | Subagent role | Instructions |
|---|---|---|
| Problem discovery, user needs, assumptions, unknowns, evidence requests | Research analyst | Produce evidence-backed dossier: problem, users, constraints, alternatives, evidence, unknowns. Do not produce implementation plans. |
| Vision, scope, value proposition, outcomes, product direction | Product strategist | Return vision summary, success metrics, open questions, biggest product risk. |
| Milestones, dependencies, sequencing, estimates, roadmap | Roadmap planner | Return critical path, risk-adjusted sequencing, confidence per milestone, dependency map. |
| Acceptance criteria, quality checks, release readiness, pass/fail | Quality gatekeeper | Return PASS/FAIL with exact remediation items. Never approve vague outputs. |
| MCP, integrations, auth, permissions, hooks, plugins, operations | Integration operator | Return operational checklist, rollback notes, top integration risk. |

When multiple domains match, invoke agents in parallel and synthesize a consolidated response.

## Swift 6 Strict Concurrency (Non-Negotiable)

This project uses **Swift 6 language mode** with **strict concurrency checking: complete** and **default actor isolation: MainActor**. All code must compile cleanly — no "it works but warns" acceptance.

Full specification: `docs/operating-model/swift-concurrency-rules.md`. Key rules:

### Two-Layer Architecture (Non-Negotiable)

The app is split into two strict layers. Violating this separation causes UI lag.

**Data layer** (background — NEVER on MainActor):
- **`DataWriter`** (`@ModelActor` actor) — owns its own `ModelContext`. ALL SwiftData writes (persist, classify, extract, purge) happen here. Pre-computes display fields (`plainText`, `formattedDate`, `primaryCategory`) at write time so UI does zero computation.
- **`FeedbinClient`** (`actor`) — all network requests.
- **Pure helpers** (`nonisolated`) — `stripHTMLToPlainText`, `formatEntryDate`, `detectLanguage`.

**UI layer** (MainActor — read-only, zero computation):
- **SwiftUI views** read pre-computed data via `@Query` with SQLite-level predicates (e.g., `primaryCategory == category`). Never filter in Swift.
- **`SyncEngine`** / **`ClassificationEngine`** stay `@MainActor @Observable` but ONLY for progress display (integers, booleans). They delegate all data operations to `DataWriter` via `await`. Zero `ModelContext` usage.
- **`EntryRowView`** reads `entry.formattedDate` directly. No `Calendar` operations at render time.
- **`EntryDetailView`** reads `entry.plainText` directly. No HTML stripping at render time.

### Strict rules

- NO `ModelContext` on MainActor for writes — all writes go through `DataWriter`.
- NO computed properties that filter/transform `@Query` results in Swift — push predicates to `@Query`.
- NO expensive computation (regex, Calendar, loops over entries) during view rendering.
- Pre-compute ALL display data at persist time inside `DataWriter`.

### Actor boundaries

- **DTOs crossing actors**: `nonisolated struct` + `Sendable` (e.g., `ClassificationInput`, `ClassificationResult`, `CategoryDefinition`).
- **`@Model` objects** never cross actor boundaries. Pass `PersistentIdentifier` or Sendable DTOs instead.
- **`DataWriter`** must be created from a background context (not from MainActor) to ensure its executor runs off the main queue.

### Mandatory patterns

- `private let` for module-level `Logger` constants. Inside non-MainActor actors, use `private static let` instead.
- `Task {}` for UI-triggered async work. `Task.sleep(for:)` for periodic timers.
- Structured concurrency only: `async let`, `TaskGroup`, cancellation via `Task.isCancelled`.

### Strict prohibitions

- NO `DispatchQueue` / GCD / semaphores / `NSLock` / `OperationQueue`.
- NO completion-handler APIs.
- NO `Combine` for async orchestration.
- NO `withCheckedContinuation` / `withCheckedThrowingContinuation`.
- NO `Timer.scheduledTimer` — use `Task.sleep(for:)` loops.
- NO `[weak self]` capture lists in Task closures.

### Verification

```bash
xcodebuild -project Feeder.xcodeproj -scheme Feeder -configuration Debug build 2>&1 | grep -E "(error:|warning:)"
# Must produce zero output
```

## Git Conventions

- Conventional Commits: `<type>(<scope>): <summary>`
- One worktree per session, one task branch, one PR scope.
- Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `chore/<topic>`.
- PRs target `main` only. Never push directly to `main`.
- Run `bash .claude/scripts/use-github-app-auth.sh` before push/PR to refresh GitHub App token.

## Prohibited Actions

- No force push (`--force`, `--force-with-lease`).
- No `rm -rf`.
- No reading `.env` files.
- No pushing directly to `main` or `master`.
- No weakening Xcode concurrency settings.

## SwiftData Schema Versioning

The app uses a versioned schema with auto-reset instead of migrations (`FeederApp.swift`). When the schema changes (adding/removing/renaming fields on `@Model` classes), bump `currentSchemaVersion` in `FeederApp.swift`. On startup, if the stored version differs, the database is deleted and a fresh 7-day sync runs automatically. Never write migration code — this app is not published.

## Quality Expectations

- All claims must include evidence or source links.
- Risks, assumptions, and unknowns must be explicit.
- Changes to priorities require updated roadmap rationale.
- The build must remain clean (zero errors, zero warnings) after every change.
