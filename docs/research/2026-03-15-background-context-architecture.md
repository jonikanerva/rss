# Research Dossier: Background ModelContext Architecture

**Date**: 2026-03-15
**Status**: Complete — sufficient to plan
**Researcher**: Claude agent

---

## 1. Problem Framing

All SwiftData writes in Feeder (fetch persist, classification updates, extracted content) happen on the view's MainActor ModelContext. Every `context.save()` triggers `@Query` re-evaluation → full Entry re-fetch → O(n) Swift filter → full list re-render with expensive per-row Calendar computations. The UI is fundamentally unresponsive because data processing and display share the same execution context.

The goal: separate the app into two clean layers:
1. **Data layer** — background processes that keep the database populated with clean, display-ready data
2. **UI layer** — reactive, read-only view that renders pre-computed data from the database with zero computation

---

## 2. Users and Jobs

| User | Job | Current pain |
|------|-----|-------------|
| Daily reader | Open app, scroll articles, read | Every classification save blocks scrolling for 100-500ms |
| Power user | Browse while sync runs | Sync persist batches block UI for 50-200ms per batch |
| Any user | Click article to read | formatEntryDate runs Calendar ops per visible row per render |

---

## 3. Constraints and Assumptions

### Hard constraints
- Swift 6 strict concurrency (complete checking, MainActor default)
- `ModelContext` is NOT Sendable — cannot cross actor boundaries
- `@Model` objects are NOT Sendable — must pass `PersistentIdentifier` between actors
- No GCD, Combine, completion handlers
- App unpublished — no migration concerns (bump schema version)

### Assumptions
- SwiftData `@ModelActor` is the sanctioned pattern for background writes
- `@Query` should react to background context saves (known to be unreliable — see evidence)
- macOS Sequoia List has lazy rendering (improved but not as aggressive as iOS)

---

## 4. Alternatives and Tradeoffs

### Alternative A: `@ModelActor` for Background Writes (Recommended)

**How it works**: Create a `@ModelActor` actor that owns its own `ModelContext`. All sync and classification writes happen there. The view context receives changes via SwiftData's store-level merge. UI uses `@Query` with predicates pushed to SQLite.

**Pros**:
- Zero MainActor blocking for data writes
- Apple's sanctioned pattern for background SwiftData
- Clean actor boundary — data layer is a proper actor, not MainActor
- `DefaultSerialModelExecutor` handles context-queue alignment automatically

**Cons**:
- `@Query` reactivity after background saves is unreliable (known iOS 18/macOS 15 bugs — inserts sometimes don't trigger updates)
- Cannot pass `@Model` objects between actors — must use `PersistentIdentifier` and re-fetch
- Two contexts can have stale views of each other's uncommitted changes
- SyncEngine and ClassificationEngine need significant refactoring from `@MainActor @Observable` to `@ModelActor`

**Mitigation for @Query bug**: Observe `.NSManagedObjectContextDidSave` notification to force view context refresh. Or keep a MainActor `@Observable` status object for progress/state while the actual data writes happen on the background actor.

**Verdict**: Best option despite @Query reliability concerns. The alternative (MainActor writes) is fundamentally broken for responsiveness.

### Alternative B: Keep MainActor Writes, Optimize UI Layer Only

**How it works**: Keep current architecture but: (1) pre-compute `formattedDate` in database, (2) increase save interval from 25 to 100+ entries, (3) replace computed `filteredEntries` with a @Query predicate.

**Pros**:
- Minimal refactoring
- No @Query reactivity risk
- No actor boundary complexity

**Cons**:
- Persist batches still block MainActor for 50-200ms
- `context.save()` still triggers full @Query re-fetch
- Fundamentally the wrong architecture — treating symptoms not cause

**Verdict**: Band-aid. Reduces pain but doesn't fix the fundamental problem.

### Alternative C: Hybrid — Background Writes + MainActor Status Object

**How it works**: Combine A's background actor for data writes with a lightweight `@MainActor @Observable` object for UI progress state (fetchedCount, isClassifying, etc.). The progress object has no SwiftData dependency — it's just integers and booleans. Data writes happen on the `@ModelActor`. UI reads via `@Query`.

**Pros**:
- All data writes off MainActor (like A)
- Progress UI updates are trivial MainActor property writes (microseconds)
- Clean separation: progress state ≠ data state
- If @Query reactivity fails, can add manual refresh trigger

**Cons**:
- Two objects per engine (actor + progress observable) — more code
- Must wire progress updates from background actor to MainActor observable

**Verdict**: This is actually the refined version of A. Recommended approach.

---

## 5. Evidence

### 5.1 `@ModelActor` Background Writes

Apple's sanctioned pattern for background SwiftData operations. The macro generates:
- `init(modelContainer:)` that creates a fresh `ModelContext`
- `DefaultSerialModelExecutor` that ties the actor's queue to the context's queue
- `modelContext` computed property via the `ModelActor` protocol

**Critical**: The executor inherits its serial queue from the thread running `init`. If created from MainActor, it runs on main queue. Must create from `Task.detached`.

```swift
@ModelActor
actor DataProcessor {
    func persistEntries(_ dtos: [EntryDTO]) throws {
        for dto in dtos {
            let entry = Entry(...)
            modelContext.insert(entry)
        }
        try modelContext.save()
    }
}

// Must init from background:
Task.detached {
    let processor = DataProcessor(modelContainer: container)
    try await processor.persistEntries(dtos)
}
```

- Source: [Use Your Loaf — SwiftData Background Tasks](https://useyourloaf.com/blog/swiftdata-background-tasks/)
- Source: [Fatbobman — Concurrent Programming in SwiftData](https://fatbobman.com/en/posts/concurret-programming-in-swiftdata/)
- Source: [BrightDigit — Using ModelActor](https://brightdigit.com/tutorials/swiftdata-modelactor/)

### 5.2 `@Query` Reactivity — Known Bugs

Background context saves do **not** reliably trigger `@Query` updates on iOS 18 / macOS 15. Multiple Apple Developer Forums threads document this regression:
- Inserts from `@ModelActor` sometimes don't trigger `@Query` updates (deletes do)
- Updates that worked on iOS 17 stopped reflecting in views on iOS 18

**Workaround**: Observe `Notification.Name.NSManagedObjectContextDidSave` and force the view context to re-read:
```swift
NotificationCenter.default.addObserver(
    forName: .NSManagedObjectContextDidSave,
    object: nil, queue: .main
) { _ in
    // Force @Query refresh by touching the view context
}
```

- Source: [Apple Forums — Saving SwiftData in Background Does Not Update @Query](https://developer.apple.com/forums/thread/758882)
- Source: [Apple Forums — SwiftData background inserts](https://developer.apple.com/forums/thread/734177)

### 5.3 `@Query` Array Predicate Crashes

`categoryLabels.contains("technology")` where `categoryLabels: [String]` **crashes at runtime** with `EXC_BAD_ACCESS`. SwiftData stores `[String]` as binary plist — contents cannot be queried at SQLite level.

**Options**:
1. Denormalized `primaryCategory: String` field — queryable, simple
2. Relationship model (Category ↔ Entry many-to-many) — queryable but complex
3. Post-fetch filter (current approach) — works but O(n)

Option 1 is best for our case: most UI filtering is by one category at a time.

- Source: [Apple Forums — SwiftData Predicates and .contains](https://developer.apple.com/forums/thread/747226)
- Source: [Apple Forums — SwiftData using Predicate on an Array](https://developer.apple.com/forums/thread/747296)

### 5.4 SwiftUI List Performance

macOS Sequoia `List` has improved lazy rendering but is still not as aggressive as iOS. Key facts:
- List assigns unique identity per row — no UITableView-style cell reuse
- When @Query updates, SwiftUI diffs by row `id` — unchanged rows are skipped
- Extracting rows into separate `struct` types helps SwiftUI skip re-evaluation
- Stable IDs (e.g., `feedbinEntryID`) are critical for efficient diffing

- Source: [Apple — Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
- Source: [Apple Forums — Slow rendering List backed by SwiftData @Query](https://developer.apple.com/forums/thread/766201)

### 5.5 Pre-Computed Display Fields

Storing `formattedDate: String` and `plainText: String` in the database is a standard denormalization pattern. SwiftData handles additional String columns efficiently — they're just SQLite TEXT columns. The trade-off (storage vs. compute) heavily favors pre-computation for display-only data that would otherwise be recalculated on every render.

---

## 6. Unknowns and Risk Flags

| # | Unknown | Impact | Mitigation |
|---|---------|--------|-----------|
| 1 | **@Query reactivity after background save** — known to be unreliable on macOS 15. Will our @Query update when the background actor saves? | High — UI might not reflect new articles | Add manual refresh mechanism (notification observer or explicit view context touch). Test thoroughly. |
| 2 | **@ModelActor queue inheritance** — if init runs on MainActor, actor executes on main queue | High — defeats entire purpose | Always create @ModelActor from Task.detached. Add assertions or logging to verify. |
| 3 | **Two-context race conditions** — background actor and view context reading simultaneously | Medium — stale data possible | Both contexts share the persistent store. Saves are atomic at SQLite level. Stale reads are acceptable for UI (next merge cycle fixes). |
| 4 | **SyncEngine state management** — currently @Observable properties (isSyncing, fetchedCount) drive UI. Moving to @ModelActor means these can't be @Observable anymore | Medium — need separate progress mechanism | Hybrid approach: lightweight @MainActor @Observable for UI progress, @ModelActor for data writes. |
| 5 | **`primaryCategory` denormalization** — adding a queryable field means classification must set it. What if an article has multiple categories? | Low — pick first/primary category for filtering | Use first assigned category as primaryCategory. categoryLabels still stores the full list. |

---

## 7. Stance and Recommendations

### Evidence sufficiency
**Sufficient to plan.** The `@ModelActor` pattern is well-documented, the @Query reactivity bug is a known issue with documented workarounds, and the array predicate limitation has clear alternatives.

### Single most critical unknown
**#1: @Query reactivity after background saves.** If @Query doesn't update, the entire background-context approach requires a manual refresh mechanism. This must be tested immediately in the implementation.

### Recommended next action
Proceed to `/plan` with Alternative C (hybrid: @ModelActor for data + @MainActor @Observable for progress). The plan should address:
1. `@ModelActor` actor for SyncEngine data operations
2. `@ModelActor` actor for ClassificationEngine data operations
3. Lightweight `@MainActor @Observable` progress objects for UI state
4. `primaryCategory: String` denormalized field on Entry for @Query predicate
5. `formattedDate: String` pre-computed field on Entry
6. @Query reactivity workaround (notification observer)
7. Schema version bump
