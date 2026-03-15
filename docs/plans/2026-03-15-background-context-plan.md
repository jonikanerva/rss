# Implementation Plan: Background ModelContext Architecture

**Date**: 2026-03-15
**Research**: `docs/research/2026-03-15-background-context-architecture.md`
**Approach**: Alternative A — Clean `@ModelActor` reference implementation targeting macOS 26 Tahoe
**PR**: Same `feat/startup-pipeline` branch

---

## Scope and Objectives

Separate the app into two clean layers, following Apple's intended SwiftData architecture:

1. **Data layer** — `@ModelActor` background actor handles all SwiftData writes. Zero MainActor blocking.
2. **UI layer** — `@Query` reads pre-computed, display-ready data directly from SQLite. Zero computation at render time.

No workarounds for Sequoia-era bugs. Target Tahoe as a reference implementation of how SwiftUI + SwiftData should be used.

---

## Milestones and Dependencies

### M1: Entry Model — Pre-Computed Display Fields
**Confidence: High**

**Files**: `Feeder/Models/Entry.swift`, `Feeder/FeederApp.swift`

- Add `formattedDate: String = ""` — pre-computed at persist time (e.g., "Today, 5th Mar, 21:24")
- Add `primaryCategory: String = ""` — first assigned category, queryable by `@Query` predicate
- `plainText` already exists
- Bump `currentSchemaVersion` to 3

---

### M2: DataWriter — Background @ModelActor
**Confidence: Medium**

**Files**: New `Feeder/DataWriter.swift`

A `@ModelActor` actor that owns its own `ModelContext` and handles ALL SwiftData writes:

```swift
@ModelActor
actor DataWriter {
    func persistEntries(_ entries: [FeedbinEntry], markAsRead: Bool) throws -> Int
    func persistEntries(_ entries: [FeedbinEntry], unreadIDs: Set<Int>) throws -> Int
    func syncFeeds(_ subscriptions: [FeedbinSubscription]) throws
    func updateReadState(unreadIDs: Set<Int>) throws
    func applyClassification(entryID: Int, result: ClassificationResult) throws
    func applyExtractedContent(results: [(entryID: Int, content: String)]) throws
    func purgeEntriesOlderThan(_ cutoff: Date) throws
    func fetchUnclassifiedInputs() throws -> [ClassificationInput]
    func fetchExtractedContentRequests() throws -> [(entryID: Int, url: String)]
    func fetchCategoryDefinitions() throws -> [(label: String, description: String)]
    func resetClassification() throws
}
```

Design rules:
- All methods work with `Sendable` DTOs — never exposes `@Model` objects
- All pre-computation happens inside: `stripHTMLToPlainText`, `formatEntryDate`, `primaryCategory`
- `plainTexts` dictionary no longer passed from caller — DataWriter computes internally
- Saves after each batch operation
- Created from `Task.detached` to ensure background execution

---

### M3: SyncEngine — Thin Orchestrator
**Confidence: Medium**

**Files**: `Feeder/FeedbinAPI/SyncEngine.swift`

SyncEngine stays `@MainActor @Observable` for progress UI but loses all `ModelContext` usage:
- Calls `FeedbinClient` for network → background actor
- Calls `DataWriter` for persistence → background actor
- Updates own `@Observable` properties (isSyncing, fetchedCount) → MainActor, microseconds

The only MainActor work: integer/boolean property writes for status display.

Changes:
- Remove `ModelContext` reference entirely
- `configure(username:password:modelContainer:)` — stores container, creates DataWriter in `Task.detached`
- Replace all `persistEntries(...)` → `await writer.persistEntries(...)`
- Replace `fetchExtractedContentParallel(...)` → `writer.fetchExtractedContentRequests()` + network + `writer.applyExtractedContent(...)`
- Remove `stripHTMLToPlainText` function from this file
- Remove all `context.save()` calls

---

### M4: ClassificationEngine — No ModelContext
**Confidence: Medium**

**Files**: `Feeder/Classification/ClassificationEngine.swift`

Stays `@MainActor @Observable` for progress. All SwiftData via DataWriter:

1. `let inputs = await writer.fetchUnclassifiedInputs()` — background read
2. Per entry: `Task.detached` for FM inference — background compute
3. `await writer.applyClassification(entryID:result:)` — background write
4. `classifiedCount += 1` — MainActor, microseconds

- `startContinuousClassification(writer:)` replaces `startContinuousClassification(in:)`
- `reclassifyAll(writer:)` calls `writer.resetClassification()`
- Remove all `ModelContext` parameters and references

---

### M5: ContentView — Pure Display Layer
**Confidence: High**

**Files**: `Feeder/Views/ContentView.swift`, `Feeder/Views/EntryRowView.swift`

1. **Dynamic @Query with predicate** — sub-view pattern for category filtering:
   ```swift
   struct EntryListView: View {
       @Query private var entries: [Entry]
       init(category: String) {
           _entries = Query(
               filter: #Predicate<Entry> { $0.isClassified && $0.primaryCategory == category },
               sort: \Entry.publishedAt,
               order: .reverse
           )
       }
   }
   ```
   Replaces `filteredEntries` O(n) Swift filter with SQLite WHERE clause.

2. **EntryRowView** — `Text(entry.formattedDate)` directly, delete `formatEntryDate()` function entirely

3. **Remove** the all-entries `@Query` — only the category-filtered sub-view query remains

4. **startSync()** — pass `modelContainer` not `modelContext`; purge via DataWriter

5. **Demo/preview data** — set `formattedDate` and `primaryCategory` on seeded entries

---

## Critical Path

```
M1 (model) → M2 (DataWriter) → M3 (SyncEngine) → M4 (ClassificationEngine) → M5 (ContentView)
```

M2 is the bottleneck — all other milestones depend on DataWriter.

---

## Risks and Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|-----------|
| 1 | **@ModelActor inits on MainActor queue** | High — defeats purpose | Create from `Task.detached`. Log thread in debug builds. |
| 2 | **@Query reactivity on Tahoe** | Medium — if broken, it's Apple's bug | Trust the framework. File radar if needed. No workarounds. |
| 3 | **primaryCategory = single category** | Low — design choice | First assigned label. `categoryLabels` still stores full list. |
| 4 | **Swift 6 strict concurrency + @ModelActor** | Medium — compile complexity | Follow Apple docs, test each milestone. |

---

## Acceptance Criteria

### M1
- [ ] `formattedDate`, `primaryCategory` fields on Entry
- [ ] Schema version = 3

### M2
- [ ] `@ModelActor actor DataWriter` compiles, runs off MainActor
- [ ] Pre-computes plainText, formattedDate, primaryCategory
- [ ] All methods use Sendable DTOs

### M3
- [ ] SyncEngine has zero ModelContext references
- [ ] All writes via DataWriter
- [ ] Progress @Observable properties still work

### M4
- [ ] ClassificationEngine has zero ModelContext references
- [ ] FM inference in Task.detached, writes via DataWriter

### M5
- [ ] @Query with primaryCategory predicate (SQLite-level)
- [ ] EntryRowView uses entry.formattedDate (zero Calendar ops)
- [ ] UI fully responsive during sync + classification

---

## Quality Gates

- [ ] `xcodebuild build` — zero errors, zero warnings
- [ ] Manual: scroll while sync runs — zero lag
- [ ] Manual: click articles while classifying — instant
- [ ] Manual: articles appear progressively as classified
