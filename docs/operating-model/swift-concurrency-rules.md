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

## Architecture boundaries

### UI layer: `@MainActor` (default)
- All SwiftUI views, `@Observable` classes, and UI-facing state are `@MainActor`.
- With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, this is the default — no annotation needed for most types.
- ViewModels and engine classes that hold UI state (`SyncEngine`, `ClassificationEngine`, `GroupingEngine`) are explicitly `@MainActor @Observable`.

### API layer: `actor` or `nonisolated`
- Networking code must NOT run on MainActor.
- Use `actor` for stateful API clients (e.g., `FeedbinClient`).
- All REST calls use `URLSession` native async APIs (`data(from:)`, `data(for:)`).
- No `@MainActor` on API types.

### Shared utilities: `nonisolated`
- Pure functions, Keychain helpers, error types, and stateless utilities use `nonisolated`.
- Example: `nonisolated enum KeychainHelper`, `nonisolated enum FeedbinError`.

### DTOs crossing actor boundaries: `nonisolated struct` + `Sendable`
- All Decodable model types that are decoded inside an `actor` must be `nonisolated struct`.
- Without `nonisolated`, the default MainActor isolation makes their Decodable conformance MainActor-isolated, which cannot be used from inside another actor.
- Example: `nonisolated struct FeedbinEntry: Decodable, Sendable`.

### SwiftData `@Model` classes
- `@Model` classes (Feed, Entry, Category, StoryGroup) live on MainActor (the default).
- They are manipulated only via `ModelContext` on the MainActor.
- They do NOT cross actor boundaries — API data comes in as Sendable DTOs, then gets mapped to @Model objects on MainActor.

## Mandatory patterns

### Logger constants
```swift
private nonisolated(unsafe) let logger = Logger(subsystem: "com.feeder.app", category: "MyModule")
```
- `Logger` is Sendable, but `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes top-level `let` constants MainActor-isolated.
- `nonisolated(unsafe)` opts out of isolation for these known-safe constants.
- Every module-level Logger must use this pattern.

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
