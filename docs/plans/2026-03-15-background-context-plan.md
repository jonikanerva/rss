# Implementation Plan: Background ModelContext Architecture

**Date**: 2026-03-15
**Research**: `docs/research/2026-03-15-background-context-architecture.md`
**Approach**: Alternative C — @ModelActor for data writes + @MainActor @Observable for progress
**PR**: Same `feat/startup-pipeline` branch

---

## Scope and Objectives

Separate the app into two layers:

1. **Data layer** — `@ModelActor` background actor handles all SwiftData writes (persist, classify, extract). Zero MainActor blocking.
2. **UI layer** — `@Query` reads pre-computed, display-ready data. Zero computation at render time.

Result: UI stays responsive regardless of how many articles are being fetched or classified.

---

## Milestones and Dependencies

### M1: Entry Model — Add Pre-Computed Display Fields
**Confidence: High**

**Files**: `Feeder/Models/Entry.swift`

**Changes**:
- Add `formattedDate: String = ""` — pre-computed at persist time (e.g., "Today, 5th Mar, 21:24")
- Add `primaryCategory: String = ""` — first assigned category label, queryable by @Query predicate
- `plainText` already exists
- Bump `currentSchemaVersion` to 3 in `FeederApp.swift`

**Dependencies**: None.

---

### M2: DataWriter — Background @ModelActor
**Confidence: Medium**

**Files**: New file `Feeder/DataWriter.swift`

**Changes**:

Create a `@ModelActor` actor that owns all SwiftData write operations:

```swift
@ModelActor
actor DataWriter {
    // Persist entries from Feedbin DTOs
    func persistEntries(_ entries: [FeedbinEntry], markAsRead: Bool, plainTexts: [Int: String]) throws -> Int

    // Persist entries with unread ID set
    func persistEntries(_ entries: [FeedbinEntry], unreadIDs: Set<Int>, plainTexts: [Int: String]) throws -> Int

    // Sync feeds
    func syncFeeds(_ subscriptions: [FeedbinSubscription]) throws

    // Update read state
    func updateReadState(unreadIDs: Set<Int>) throws

    // Apply classification result to one entry
    func applyClassification(entryID: Int, result: ClassificationResult) throws

    // Apply extracted content + update plainText
    func applyExtractedContent(results: [(entryID: Int, content: String)]) throws

    // Purge old entries
    func purgeEntriesOlderThan(_ cutoff: Date) throws

    // Fetch unclassified entry data for classification (returns Sendable DTOs, not @Model objects)
    func fetchUnclassifiedInputs() throws -> [ClassificationInput]

    // Fetch entries needing extracted content (returns Sendable tuples)
    func fetchExtractedContentRequests() throws -> [(entryID: Int, url: String)]

    // Fetch category definitions (returns Sendable data)
    func fetchCategories() throws -> [(label: String, description: String)]
}
```

Key design rules:
- All methods work with Sendable DTOs, never expose `@Model` objects across actor boundary
- All pre-computation (stripHTML, formatDate) happens inside this actor
- `persistEntries` computes `plainText`, `formattedDate`, and sets `primaryCategory = ""` (not yet classified)
- `applyClassification` sets `categoryLabels`, `storyKey`, `isClassified`, `primaryCategory` (first label)
- `applyExtractedContent` updates `extractedContent`, recomputes `plainText`
- saves after each batch operation

**Critical**: Must be created from `Task.detached` to ensure background execution:
```swift
Task.detached {
    let writer = DataWriter(modelContainer: container)
    // ...
}
```

**Dependencies**: M1.

---

### M3: SyncEngine Refactor — Orchestrator Only
**Confidence: Medium**

**Files**: `Feeder/FeedbinAPI/SyncEngine.swift`

**Changes**:

SyncEngine becomes a thin orchestrator. It no longer holds a `ModelContext` or does any SwiftData writes. It:
1. Calls `FeedbinClient` (actor) for network fetches
2. Calls `DataWriter` (actor) for persistence
3. Updates `SyncProgress` (MainActor observable) for UI

New structure:
```swift
// No longer @MainActor @Observable — just coordinates work
final class SyncEngine: Sendable {
    private let client: FeedbinClient
    private let writer: DataWriter
    private let progress: SyncProgress

    func sync() async { ... }
}
```

Wait — `SyncEngine` needs to update `SyncProgress` which is `@MainActor`. And it needs to be started/stopped from ContentView. Let's keep it simpler:

**Revised**: SyncEngine stays as a class but loses `@MainActor` and `ModelContext`. It holds references to `FeedbinClient`, `DataWriter`, and `SyncProgress`. All its methods are `async` and can run from any context.

Actually, the simplest correct approach: **keep SyncEngine as `@MainActor @Observable`** but remove all ModelContext usage. It becomes purely an orchestrator:
- Calls `client.fetch*()` — awaits network (background actor)
- Calls `writer.persist*()` — awaits database (background actor)
- Updates own `@Observable` properties for UI — MainActor (microseconds)

This way ContentView can keep using `@Environment(SyncEngine.self)` for progress display. The only MainActor work is property writes (isSyncing, fetchedCount, etc.).

**Changes summary**:
- Remove `private var modelContext: ModelContext?`
- Remove `configure(username:password:modelContext:)` → replace with `configure(username:password:modelContainer:)` that creates `DataWriter`
- Replace all `persistEntries(...)` calls with `await writer.persistEntries(...)`
- Replace `syncFeeds(...)` with `await writer.syncFeeds(...)`
- Replace `updateReadState(...)` with `await writer.updateReadState(...)`
- Replace `fetchExtractedContentParallel(...)` with calls to `writer.fetchExtractedContentRequests()` + network fetch + `writer.applyExtractedContent(...)`
- Remove `stripHTMLToPlainText` pre-computation (now inside DataWriter)
- Remove all `context.save()` calls (DataWriter saves internally)

**Dependencies**: M2.

---

### M4: ClassificationEngine Refactor — Background Classification
**Confidence: Medium**

**Files**: `Feeder/Classification/ClassificationEngine.swift`

**Changes**:

ClassificationEngine stays `@MainActor @Observable` for progress UI, but all SwiftData operations move to DataWriter:

- `classifyNextBatch()`: calls `writer.fetchUnclassifiedInputs()` to get DTOs, runs FM inference in `Task.detached`, calls `writer.applyClassification()` per entry
- No more `ModelContext` parameter — receives `DataWriter` reference
- `startContinuousClassification(writer:)` replaces `startContinuousClassification(in:)`
- `reclassifyAll()` calls writer to reset classification flags

The classification loop:
1. `let inputs = await writer.fetchUnclassifiedInputs()` — background actor reads DB
2. For each input: `Task.detached` runs FM inference — background thread
3. `await writer.applyClassification(entryID:result:)` — background actor writes DB
4. Update `classifiedCount` on MainActor — microseconds

**No ModelContext on MainActor at all.**

**Dependencies**: M2, M3.

---

### M5: ContentView — Pure Display Layer
**Confidence: High**

**Files**: `Feeder/Views/ContentView.swift`, `Feeder/Views/EntryRowView.swift`

**Changes**:

1. **@Query with predicate** — replace `filteredEntries` computed filter:
   ```swift
   // Before: @Query all entries + filter in Swift
   @Query(sort: \Entry.publishedAt, order: .reverse) private var entries: [Entry]
   private var filteredEntries: [Entry] { entries.filter { ... } }

   // After: dynamic @Query filtered by category in SQLite
   // Use a wrapper view that takes selectedCategory and builds @Query
   ```

   Since `@Query` predicates are set at init time, use a sub-view pattern:
   ```swift
   struct EntryListView: View {
       let category: String
       @Query private var entries: [Entry]

       init(category: String) {
           self.category = category
           _entries = Query(
               filter: #Predicate<Entry> {
                   $0.isClassified && $0.primaryCategory == category
               },
               sort: \Entry.publishedAt,
               order: .reverse
           )
       }
   }
   ```

   **Note**: This filters by `primaryCategory` (String equality, safe for @Query) instead of `categoryLabels.contains()` (crashes). Articles with multiple categories will appear in their primary category only. This is acceptable — the sidebar shows one category at a time.

2. **EntryRowView** — use `entry.formattedDate` directly, remove `formatEntryDate()`:
   ```swift
   Text(entry.formattedDate)  // Pre-computed string, zero Calendar ops
   ```

3. **Remove `@Query(sort: \Entry.publishedAt)` for all entries** — no longer needed for `filteredEntries`

4. **Keep `@Query(sort: \Category.sortOrder)` for categories** — small, rarely changes

5. **siblingEntries** — keep as-is for now (only runs on selection change, not on every @Query update)

6. **startSync()** — pass `modelContainer` instead of `modelContext` to SyncEngine

7. **purgeOldEntries()** — move to DataWriter, call via `await writer.purgeEntriesOlderThan(cutoff)`

8. **Demo/preview data** — set `formattedDate` and `primaryCategory` on seeded entries

**Dependencies**: M1, M3, M4.

---

### M6: @Query Reactivity Workaround
**Confidence: Low**

**Files**: `Feeder/Views/ContentView.swift` or `Feeder/FeederApp.swift`

**Changes**:

Test if @Query updates when DataWriter saves. If not, add a workaround:

Option A (preferred): Use a `@State` refresh token that increments when DataWriter saves, triggering @Query re-evaluation via `.id(refreshToken)` on the List.

Option B: Observe `.NSManagedObjectContextDidSave` notification and touch the view context.

**This milestone is conditional** — implement only if @Query doesn't react to background saves during testing.

**Dependencies**: M2, M5 (must be testable first).

---

## Critical Path

```
M1 (Entry model) → M2 (DataWriter) → M3 (SyncEngine) → M4 (ClassificationEngine) → M5 (ContentView)
                                                                                    → M6 (if needed)
```

M2 is the critical bottleneck — everything depends on DataWriter.

---

## Risks and Mitigations

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|-----------|-----------|
| 1 | **@Query doesn't react to background saves** | High — articles don't appear | Medium (known macOS 15 bug) | M6 workaround: refresh token or notification observer |
| 2 | **@ModelActor runs on MainActor queue** | High — defeats entire purpose | Medium (if init called from MainActor) | Always create from Task.detached. Add logging to verify thread. |
| 3 | **DataWriter save conflicts with view context** | Medium — stale data | Low (SQLite handles concurrent reads) | Acceptable: UI catches up on next merge cycle |
| 4 | **primaryCategory doesn't cover multi-category filtering** | Low — articles appear in one category only | High (by design) | Acceptable for sidebar. Can add "All" category later. |
| 5 | **SwiftData `@ModelActor` macro + Swift 6 strict concurrency** | Medium — compile errors | Medium | Follow documented patterns, test incrementally |

---

## Acceptance Criteria

### M1: Entry Model
- [ ] `formattedDate` and `primaryCategory` fields exist
- [ ] Schema version bumped to 3

### M2: DataWriter
- [ ] `@ModelActor actor DataWriter` compiles and runs off MainActor
- [ ] All persist/update methods work with Sendable DTOs
- [ ] Pre-computes plainText, formattedDate at persist time
- [ ] Sets primaryCategory from classification results

### M3: SyncEngine
- [ ] No ModelContext reference
- [ ] All writes delegated to DataWriter (background)
- [ ] Progress properties still update on MainActor (isSyncing, fetchedCount, etc.)
- [ ] UI doesn't block during sync

### M4: ClassificationEngine
- [ ] No ModelContext reference
- [ ] Reads/writes via DataWriter
- [ ] FM inference stays in Task.detached
- [ ] Progress properties update on MainActor

### M5: ContentView
- [ ] `@Query` with `primaryCategory` predicate — no computed filter
- [ ] `EntryRowView` uses `entry.formattedDate` — no Calendar ops
- [ ] Zero MainActor computation on render
- [ ] Articles appear in list as they're classified (reactivity)
- [ ] UI is fully responsive during sync + classification

### M6: Reactivity Workaround (if needed)
- [ ] @Query updates when DataWriter saves
- [ ] If not: refresh mechanism triggers list update

---

## Quality Gates

- [ ] `xcodebuild build` — zero errors, zero warnings
- [ ] Manual test: scroll articles while sync runs — zero lag
- [ ] Manual test: click articles while classification runs — instant detail view
- [ ] Manual test: articles appear progressively as classified
- [ ] Instruments: MainActor usage during sync/classify is <5ms per event

---

## Top Delivery Risk

**@Query reactivity (M6)**. If background saves don't trigger @Query updates, we need a manual refresh mechanism. This is the one unknown that could require significant additional work. Test early by implementing M2 first and verifying that a background save causes @Query to update in a simple test view.

## Recommended Next Decision

Approve this plan, then `/implement`. Start with M1+M2 and immediately test @Query reactivity before proceeding to M3-M5.
