# Swift 6 Strict Concurrency Rules

Date: 2026-03-05
Owner: Repository Owner + Agent
Status: Active — enforced in Xcode project settings

## Purpose

Define the concurrency model for the Feeder macOS app. All code must compile cleanly under Swift 6 with strict concurrency checking complete. No warnings, no workarounds, no legacy patterns.

## Project configuration (non-negotiable)

These settings are configured in `Feeder.xcodeproj` and must not be weakened:

| Setting | Value | Effect |
|---------|-------|--------|
| `SWIFT_VERSION` | `6.0` | Swift 6 language mode |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | All concurrency diagnostics are errors |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` | All types default to @MainActor unless explicitly opted out |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` | Enables approachable concurrency features |

## Two-layer architecture (non-negotiable)

The app is split into a **data layer** (background) and a **UI layer** (MainActor, read-only). This separation guarantees UI responsiveness. Never violate it.

### Data layer: background actors

- **`DataWriter`** (`@ModelActor` actor in `Feeder/DataWriter.swift`) — owns its own `ModelContext` on a background serial queue. ALL SwiftData writes happen here: persist entries, apply classification, update extracted content, purge old data. Pre-computes all display fields (`plainText`, `formattedDate`, `primaryCategory`) at write time.
- **`FeedbinClient`** (`actor`) — all HTTP requests via `URLSession` async APIs.
- **Pure helpers** (`nonisolated` functions) — `stripHTMLToPlainText`, `formatEntryDate`, `detectLanguage`, `normalizeStoryKey`. Called from background actors, never from views.

### UI layer: `@MainActor` (read-only)

- **SwiftUI views** read pre-computed data via `@Query` with SQLite-level predicates. Never filter `@Query` results in Swift — push predicates to the `@Query` initializer.
- **`SyncEngine`** / **`ClassificationEngine`** are `@MainActor @Observable` for progress display ONLY (integers, booleans, strings). They hold zero `ModelContext` references and delegate all data work to `DataWriter` via `await`.
- **`EntryRowView`** renders `entry.formattedDate` (pre-computed String). Zero `Calendar` operations.
- **`EntryDetailView`** renders `entry.plainText` (pre-computed String). Zero HTML stripping.

### Rules that protect responsiveness

| Rule | Why |
|------|-----|
| No `ModelContext` on MainActor for writes | Every `save()` on the view context triggers `@Query` re-evaluation and list re-render |
| No computed filters on `@Query` results | O(n) Swift filter on every `@Query` update defeats lazy rendering |
| No expensive computation during rendering | Calendar, regex, loops over entries block MainActor and cause visible lag |
| Pre-compute display fields in `DataWriter` | Data is display-ready when `@Query` reads it — zero transformation needed |

### Actor boundary rules

- **DTOs crossing actors**: `nonisolated struct` + `Sendable` (e.g., `ClassificationInput`, `ClassificationResult`, `CategoryDefinition`, `FeedbinEntry`).
- **`@Model` objects** never cross actor boundaries. Pass `PersistentIdentifier` or Sendable DTOs.
- **`DataWriter`** init must happen on a background thread. If created from `@MainActor` context, its executor will run on the main queue, defeating the purpose.

### Shared utilities: `nonisolated`
- Pure functions, Keychain helpers, error types use `nonisolated`.
- Example: `nonisolated enum KeychainHelper`, `nonisolated enum FeedbinError`.

## Mandatory patterns

### Logger constants
```swift
private let logger = Logger(subsystem: "com.feeder.app", category: "MyModule")
```
- With `SWIFT_APPROACHABLE_CONCURRENCY = YES`, the compiler recognizes that `Logger` is `Sendable` and does not require `nonisolated(unsafe)` for module-level constants **when used from `@MainActor` context** (the default isolation).
- Simply use `private let` — no special annotation needed for most files.
- **Exception**: If the logger is used inside a non-MainActor `actor` (e.g., `actor FeedbinClient`), a top-level `let` defaults to `@MainActor` isolation and cannot be accessed from the other actor. Use a `private static let` inside the actor instead:
```swift
actor FeedbinClient {
    private static let logger = Logger(subsystem: "com.feeder.app", category: "FeedbinClient")
    // Access as: FeedbinClient.logger.info(...)
}
```

### Periodic tasks
```swift
// CORRECT: Task.sleep loop with cancellation
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

func stopPeriodicWork() {
    periodicTask?.cancel()
    periodicTask = nil
}
```

### UI-triggered async work
```swift
Button("Sync") {
    Task { await syncEngine.sync() }
}
```

### Stale response prevention
```swift
private var searchTask: Task<Void, Never>?

func search(_ query: String) {
    searchTask?.cancel()
    searchTask = Task {
        try? await Task.sleep(for: .milliseconds(300)) // debounce
        guard !Task.isCancelled else { return }
        // perform search
    }
}
```

## Strict prohibitions

| Prohibited | Replacement |
|-----------|-------------|
| `DispatchQueue` / GCD | `Task {}`, `async let`, `TaskGroup` |
| `OperationQueue` / `Operation` | `TaskGroup` |
| `NSLock` / semaphores | `actor` isolation |
| `Timer.scheduledTimer` | `Task.sleep(for:)` loop |
| Completion handlers | `async` functions |
| `Combine` for async orchestration | `async`/`await`, `AsyncSequence` |
| `withCheckedContinuation` | Native async API or redesign |
| `NotificationCenter` async coordination | Direct `async` calls or `AsyncStream` |
| `[weak self]` in Task closures | Structured concurrency (Task inherits actor) |

## Verification

Every change must pass:
```bash
xcodebuild -project Feeder.xcodeproj -scheme Feeder -configuration Debug build 2>&1 | grep -E "(error:|warning:)"
# Must produce zero output
```

## When touching existing code

1. If the code uses any prohibited pattern, migrate it as part of the change.
2. Do not introduce new files with legacy patterns "to be fixed later."
3. The build must remain clean (zero errors, zero warnings) after every commit.
4. If a dependency lacks async API, do NOT bridge it with continuations — find an alternative or redesign the module.
