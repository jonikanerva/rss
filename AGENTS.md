# Agentic Product Delivery Rules

## Operating Default
- Enforce RPI workflow: **Research -> Plan -> Implement** for every meaningful change.
- Research is mandatory before planning; planning is mandatory before implementation.
- Prefer custom commands (`/research`, `/plan`, `/implement`, `/gate-check`) over ad-hoc prompts for repeatability.
- Default interaction should use the RPI orchestrator, which auto-dispatches specialist agents when prompt context matches their domain.
- At session start, read `docs/STATUS.md` first, then read the full `docs/operating-model/` folder before implementation.

## Product-to-Delivery Flow
1. Research dossier drafted and challenged (problem, users, constraints, alternatives, evidence).
2. Plan generated from approved research with dependencies, risks, and acceptance criteria.
3. Quality gates defined against the plan before implementation starts.
4. Implementation executes only after gate pass and owner signoff.

## Quality Expectations
- All claims must include evidence or source links.
- Risks, assumptions, and unknowns must be explicit.
- Changes to priorities require updated roadmap rationale.

## Required Artifacts
- Research outputs live under `docs/research/`.
- Plans live under `docs/plans/`.
- Gate results live under `docs/quality-gates/`.

## Swift 6 Strict Concurrency (Non-Negotiable)

This project uses **Swift 6 language mode** with **strict concurrency checking: complete** and **default actor isolation: MainActor**. All code must compile cleanly — no "it works but warns" acceptance.

See `docs/operating-model/swift-concurrency-rules.md` for the full specification. Key rules:

### Architecture boundaries
- **UI layer**: `@MainActor` — all UI-facing state, ViewModels, `@Observable` classes.
- **API layer**: `actor` or `nonisolated` — networking code must NOT be `@MainActor`. Use `actor` for stateful API clients.
- **Shared utilities**: `nonisolated` — pure functions, Keychain helpers, error types.
- **DTOs/models crossing actors**: `nonisolated struct` + `Sendable`.

### Mandatory patterns
- `nonisolated(unsafe) let` for module-level `Logger` constants (they are Sendable but default MainActor isolation blocks cross-actor access).
- `nonisolated struct` for all Decodable DTOs used inside actors.
- `nonisolated enum` for error types used across isolation boundaries.
- `Task {}` for UI-triggered async work. `Task.sleep(for:)` for periodic timers — **never** `Timer.scheduledTimer`.
- Structured concurrency only: `async let`, `TaskGroup`, cancellation via `Task.isCancelled`.

### Strict prohibitions
- NO `DispatchQueue` / GCD / semaphores / `NSLock` / `OperationQueue`.
- NO completion-handler APIs.
- NO `Combine` for async orchestration.
- NO `withCheckedContinuation` / `withCheckedThrowingContinuation`.
- NO `Timer.scheduledTimer` — use `Task.sleep(for:)` loops.
- NO `[weak self]` capture lists in Task closures (structured concurrency handles lifetimes).

### When touching existing code
- Migrate toward Swift 6 strict-concurrency rather than extending legacy patterns.
- The build must remain clean (zero errors, zero warnings) after every change.
