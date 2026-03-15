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

### Architecture boundaries

- **UI layer**: `@MainActor` (default) — all SwiftUI views, `@Observable` classes, ViewModels.
- **API layer**: `actor` or `nonisolated` — networking code must NOT be `@MainActor`.
- **Shared utilities**: `nonisolated` — pure functions, Keychain helpers, error types.
- **DTOs crossing actors**: `nonisolated struct` + `Sendable`.
- **SwiftData @Model**: MainActor (default), never cross actor boundaries.

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

## Quality Expectations

- All claims must include evidence or source links.
- Risks, assumptions, and unknowns must be explicit.
- Changes to priorities require updated roadmap rationale.
- The build must remain clean (zero errors, zero warnings) after every change.
