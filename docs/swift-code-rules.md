# Swift Rules — Feeder

All code must compile cleanly under Swift 6 with strict concurrency. Zero warnings, zero errors, no workarounds.

## Project Configuration (Non-Negotiable)

| Setting                          | Value       |
| -------------------------------- | ----------- |
| `SWIFT_VERSION`                  | `6.0`       |
| `SWIFT_STRICT_CONCURRENCY`       | `complete`  |
| `SWIFT_DEFAULT_ACTOR_ISOLATION`  | `MainActor` |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES`       |

## Core Principles

1. **Immutability by default.** Use `let` always. Use `var` only when mutation is required and justified.
2. **Pure functions for logic.** Business logic is written as pure functions with no side effects — same input always produces same output. Side effects (network, persistence, I/O) are isolated to actors.
3. **Value types over reference types.** Prefer `struct` and `enum`. Use `class` only when required by framework APIs or reference semantics are explicitly needed.
4. **No unsafe escape hatches.** `@unchecked Sendable`, `nonisolated(unsafe)`, and `assumeIsolated` are prohibited unless approved with a code comment explaining why no safe alternative exists.

## Two-Layer Architecture (Non-Negotiable)

**Data layer** (background — NEVER on MainActor):

- **`DataWriter`** (`@ModelActor`) — owns `ModelContext`. ALL writes happen here. Pre-computes display fields (`plainText`, `formattedDate`, `primaryCategory`) at write time.
- **`FeedbinClient`** (`actor`) — all HTTP requests.
- **Pure helpers** (`nonisolated`) — `stripHTMLToPlainText`, `formatEntryDate`, `detectLanguage`. These are stateless functions with zero side effects.

**UI layer** (MainActor, read-only):

- SwiftUI views read via `@Query` with SQLite-level predicates. Never filter in Swift.
- `SyncEngine`/`ClassificationEngine` are `@Observable` for progress display only. Zero `ModelContext`. Delegate to `DataWriter`.

### Why This Matters

| Rule                                      | Reason                                                      |
| ----------------------------------------- | ----------------------------------------------------------- |
| No `ModelContext` on MainActor for writes | `save()` triggers `@Query` re-evaluation and list re-render |
| No computed filters on `@Query` results   | O(n) filter on every update defeats lazy rendering          |
| No expensive computation during rendering | Calendar, regex, loops block MainActor = visible lag        |

### Actor Boundaries

- DTOs crossing actors: `nonisolated struct` + `Sendable`.
- `@Model` objects never cross boundaries — pass `PersistentIdentifier` or DTOs.
- `DataWriter` init must happen on a background thread.

## Code Style

### File Organization

**Models (`@Model`):** properties → relationships → classification fields → `init()`
**Actors/classes:** static properties (logger) → instance properties → init → methods by purpose
**Views:** `@Environment`/`@Binding` → `@State` → `@Query` → `var body` → helper views → `#Preview`
**DTOs:** properties only, marked `nonisolated` + `Sendable`

Use `// MARK: - Section Name` to separate logical concerns.

### Naming

- Booleans: predicate form — `isRead`, `isClassified`, `isTopLevel`
- Functions: descriptive verb prefix — `persist`, `fetch`, `apply`, `detect`, `strip`

### Formatting

Mechanical formatting (indentation, braces, trailing closures, casing) is enforced by `swift-format`. This section covers layout decisions it does not handle:

- Blank line between methods and between MARK sections.
- No blank lines between grouped property declarations.

### Access Control

- Default: implicit `internal` (no keyword).
- `private` for implementation details.
- `nonisolated` on helpers and DTOs crossing actor boundaries.

### Comments

- Doc comments explain _why_, not _what_.
- Inline `//` only when intent isn't obvious from code.
- Self-documenting names preferred. No over-commenting.

### Error Handling

- `if-let` only when the unwrapped value is used in the immediately following block.
- Shorthand unwrapping preferred: `guard let entry else { return }` over `guard let entry = entry`.
- `throws` for data operations that can fail.
- Typed throws when the error domain is known:

```swift
func fetchEntries() throws(FeedbinError) -> [EntryDTO]
```

### Collections

- `Dictionary(uniqueKeysWithValues:)`, `Dictionary(grouping:by:)` over manual loops.
- `map`/`filter`/`compactMap` over `for` loops for pure transformations.
- `stride(from:to:by:)` for batching.
- `lazy` for chained operations to avoid intermediate allocations:

```swift
entries.lazy.filter(\.isUnread).map(\.title).prefix(10)
```

## Mandatory Patterns

### Logging

```swift
// In @MainActor files (default isolation):
private let logger = Logger(subsystem: "com.feeder.app", category: "ModuleName")

// In non-MainActor actors:
actor FeedbinClient {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "FeedbinClient")
}
```

Log significant state changes only.

### Periodic Tasks

```swift
private var periodicTask: Task<Void, Never>?

func startPeriodicWork(interval: TimeInterval) {
  periodicTask?.cancel()
  periodicTask = Task {
    while !Task.isCancelled {
      await doWork()
      try? await Task.sleep(for: .seconds(interval))
    }
  }
}
```

### UI-Triggered Async

```swift
Button("Sync") {
  Task { await syncEngine.sync() }
}
```

## Strict Prohibitions

| Prohibited                     | Replacement                           |
| ------------------------------ | ------------------------------------- |
| `DispatchQueue` / GCD          | `Task {}`, `async let`, `TaskGroup`   |
| `OperationQueue`               | `TaskGroup`                           |
| `NSLock` / semaphores          | `actor` isolation                     |
| `Timer.scheduledTimer`         | `Task.sleep(for:)` loop               |
| Completion handlers            | `async` functions                     |
| `Combine` for async            | `async`/`await`, `AsyncSequence`      |
| `withCheckedContinuation`      | Native async API or redesign          |
| `[weak self]` in Task closures | Structured concurrency                |
| `@unchecked Sendable`          | Redesign type to be actually Sendable |
| `nonisolated(unsafe)`          | Proper actor isolation                |
| `var` where `let` suffices     | `let`                                 |

## When Touching Existing Code

1. If the code uses any prohibited pattern, migrate it as part of the change.
2. Do not introduce files with legacy patterns "to be fixed later."
3. Build must remain clean after every commit.
