# Implementation Plan: Startup Pipeline — Concurrent Fetch + Classification

**Date**: 2026-03-15
**Research**: `docs/research/2026-03-15-startup-pipeline-concurrent-fetch-classify.md`
**Approach**: Alternative B — Polling-based concurrent pipeline with shared SwiftData store
**Migration**: Not needed — app is unpublished, data can be reset

---

## Scope and Objectives

Transform the app's sequential startup pipeline (fetch → classify → group) into a concurrent pipeline where:

1. Old articles (>7 days) are purged from SwiftData on launch
2. Fetch runs as a background task with "Fetching n/x" live progress
3. Classification starts immediately alongside fetch, polling for new unclassified entries
4. Both tasks run at `.utility` priority — UI stays fully responsive
5. Uncategorized articles are hidden from all UI views until classified
6. Grouping runs incrementally after each classification batch

---

## Milestones and Dependencies

### M1: Entry Model — Add `isClassified` Flag
**Confidence: High**

**Files**: `Feeder/Models/Entry.swift`

**Changes**:
- Add `var isClassified: Bool = false` property to Entry
- No migration needed (unpublished app)

**Dependencies**: None — this is the foundation for all other milestones.

---

### M2: Startup Cleanup — 7-Day Retention Purge
**Confidence: High**

**Files**: `Feeder/Views/ContentView.swift` (in `startSync()`)

**Changes**:
- Before starting fetch, run batch delete of entries older than 7 days:
  ```swift
  let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
  let predicate = #Predicate<Entry> { $0.publishedAt < cutoff }
  try modelContext.delete(model: Entry.self, where: predicate)
  try modelContext.save()
  ```
- Also delete orphaned StoryGroup records (groups with no remaining entries)
- Run synchronously on MainActor before launching any background tasks — this is fast (SQL-level batch delete) and must complete before fetch starts to avoid deleting freshly inserted entries

**Dependencies**: None.

---

### M3: SyncEngine — Fetch Progress Counters
**Confidence: High**

**Files**: `Feeder/FeedbinAPI/SyncEngine.swift`

**Changes**:
- Add observable properties:
  ```swift
  private(set) var fetchedCount: Int = 0
  private(set) var totalToFetch: Int = 0
  ```
- **syncUnread()**: Set `totalToFetch = unreadIDs.count` after fetching unread IDs. Increment `fetchedCount` by `newCount` after each batch persist.
- **syncIncremental()**: Set `totalToFetch = entries.count` after fetching entries. Set `fetchedCount = entries.count` after persist.
- **sync()**: Reset `fetchedCount = 0` and `totalToFetch = 0` at start. Reset them to 0 when sync completes.
- New entries must be inserted with `isClassified = false` (already the default from M1).

**Dependencies**: M1.

---

### M4: ClassificationEngine — Independent Polling Task
**Confidence: Medium**

This is the most significant change. The classification engine becomes an independent background loop instead of being triggered by onChange.

**Files**: `Feeder/Classification/ClassificationEngine.swift`

**Changes**:

1. **New method: `startContinuousClassification(in:)`** — launches a long-lived Task that polls for unclassified entries:
   ```swift
   private var classificationTask: Task<Void, Never>?

   func startContinuousClassification(in context: ModelContext) {
       classificationTask?.cancel()
       classificationTask = Task {
           while !Task.isCancelled {
               await classifyNextBatch(in: context)
               try? await Task.sleep(for: .seconds(2))
           }
       }
   }
   ```

2. **New method: `classifyNextBatch(in:)`** — fetches unclassified entries (`isClassified == false`), classifies a batch, sets `isClassified = true` on each, saves:
   - Query: `#Predicate<Entry> { !$0.isClassified }`
   - Process entries in the existing one-at-a-time pattern (FM inference is the bottleneck, not iteration)
   - Update `totalToClassify` = count of unclassified entries at start of each poll cycle (this grows as fetch adds more)
   - Increment `classifiedCount` after each entry
   - Set `isClassified = true` on each entry after classification
   - Save every 25 entries + `Task.yield()`
   - If no unclassified entries found, the 2-second sleep acts as natural backoff

3. **New method: `stopContinuousClassification()`** — cancels the task.

4. **Existing `classifyUnclassified(in:)`** — refactor to use the same internal logic but as a one-shot call (for manual sync button).

5. **Set `isClassified = true`** after writing `categoryLabels` and `storyKey` to each entry.

6. **Trigger grouping** after each classification batch completes (not after entire classification finishes). Call `groupingEngine.groupEntries(in:)` — this means ClassificationEngine needs a reference to GroupingEngine, or grouping is triggered from ContentView's onChange.

**Design decision — grouping trigger**: Keep grouping triggered by ContentView's `onChange(of: classificationEngine.classifiedCount)` instead of coupling engines. When `classifiedCount` changes, check if it's a batch boundary (every 25) or if classification just finished, then trigger grouping. This avoids adding a GroupingEngine dependency to ClassificationEngine.

**Dependencies**: M1, M3 (entries must exist with `isClassified = false`).

---

### M5: ContentView — Status UI and Query Filter
**Confidence: High**

**Files**: `Feeder/Views/ContentView.swift`

**Changes**:

1. **Status text** — replace single `statusText` with two-line status:
   ```swift
   private var fetchStatusText: String? {
       guard syncEngine.isSyncing else { return nil }
       let n = syncEngine.fetchedCount
       let x = syncEngine.totalToFetch
       return x > 0 ? "Fetching \(n)/\(x)" : "Fetching..."
   }

   private var classifyStatusText: String? {
       guard classificationEngine.isClassifying else { return nil }
       let n = classificationEngine.classifiedCount
       let x = classificationEngine.totalToClassify
       return x > 0 ? "Categorizing \(n)/\(x)" : nil
   }
   ```

2. **Sidebar header** — show both lines:
   ```swift
   VStack(alignment: .leading, spacing: 2) {
       Text("News")
           .font(.system(size: 20, weight: .bold))
           .foregroundStyle(.primary)
           .textCase(nil)

       if let fetchStatus = fetchStatusText {
           Text(fetchStatus)
               .font(.system(size: 11))
               .foregroundStyle(.tertiary)
               .textCase(nil)
       }
       if let classifyStatus = classifyStatusText {
           Text(classifyStatus)
               .font(.system(size: 11))
               .foregroundStyle(.tertiary)
               .textCase(nil)
       }
       if fetchStatusText == nil && classifyStatusText == nil {
           if let syncText = lastSyncText {
               Text(syncText)
                   .font(.system(size: 11))
                   .foregroundStyle(.tertiary)
                   .textCase(nil)
           }
       }
   }
   ```

3. **Entry filtering** — change `filteredEntries` to only show classified entries:
   ```swift
   private var filteredEntries: [Entry] {
       guard let category = selectedCategory else { return [] }
       return entries.filter { $0.isClassified && $0.categoryLabels.contains(category) }
   }
   ```
   Note: The `@Query` itself stays unfiltered (no predicate change) because we need all entries for some operations. The `filteredEntries` computed property handles the filtering. This is simpler than managing a separate filtered @Query.

4. **Remove onChange triggers** — remove the three `onChange(of: syncEngine.isSyncing/isBackfilling/isFetchingContent)` handlers that trigger classification. Classification is now self-starting.

5. **Grouping trigger** — change `onChange(of: classificationEngine.isClassifying)` to trigger grouping on a batch-level basis. Simplest approach: trigger grouping when `classifiedCount` changes and hits a batch boundary (every 25), plus when classification stops:
   ```swift
   .onChange(of: classificationEngine.classifiedCount) { oldCount, newCount in
       if newCount > 0 && newCount % 25 == 0 && !groupingEngine.isGrouping {
           Task { await groupingEngine.groupEntries(in: modelContext) }
       }
   }
   .onChange(of: classificationEngine.isClassifying) { wasClassifying, isClassifying in
       if wasClassifying && !isClassifying && !groupingEngine.isGrouping {
           Task { await groupingEngine.groupEntries(in: modelContext) }
       }
   }
   ```

6. **Startup flow** — update `startSync()` to also start continuous classification:
   ```swift
   private func startSync() {
       // ... existing credential check and configure ...
       purgeOldEntries()  // M2
       syncEngine.startPeriodicSync()
       classificationEngine.startContinuousClassification(in: modelContext)
   }
   ```

7. **Demo mode data** — update `seedUITestDataIfNeeded()` to set `isClassified = true` on seeded entries.

**Dependencies**: M1, M2, M3, M4.

---

### M6: Preview and Test Fixtures
**Confidence: High**

**Files**: `Feeder/Views/ContentView.swift` (preview), any test files

**Changes**:
- Update preview data to set `isClassified = true` on seeded entries
- Update any UI test fixtures that create entries

**Dependencies**: M1.

---

## Critical Path

```
M1 (Entry model) → M3 (SyncEngine progress) → M4 (ClassificationEngine polling) → M5 (ContentView UI)
M1 → M2 (Startup purge) → M5
M1 → M6 (Fixtures)
```

**M4 is the critical path bottleneck** — it's the largest change and has medium confidence.

---

## Risks and Mitigations

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|-----------|-----------|
| 1 | **ModelContext save contention** — SyncEngine and ClassificationEngine both call `context.save()` on MainActor. Could one save() include dirty objects from the other engine's uncommitted work? | Medium — unexpected data state | Low (both are @MainActor, serialized) | Both engines save at defined batch boundaries. Test with concurrent operation to verify no cross-contamination. |
| 2 | **Classification polling misses entries** — 2-second poll interval means classification lags fetch by up to 2 seconds | Low — barely noticeable | High (by design) | Acceptable tradeoff. 2 seconds is imperceptible compared to classification time per article (~1-3s each). |
| 3 | **Grouping runs too frequently** — triggering grouping every 25 classified entries could cause UI churn | Medium — visual instability | Medium | GroupingEngine already has `guard !isGrouping` — concurrent requests are dropped. At worst, grouping runs once per 25 entries. If too frequent, increase batch threshold. |
| 4 | **FM not available on first launch** — classification polls but Apple Intelligence isn't ready | Low — classification never starts | Low | Existing availability check in ClassificationEngine handles this. Polling will re-check every 2 seconds until available. |
| 5 | **Memory pressure** — fetching + classifying + grouping all active with hundreds of entries in context | Medium — app sluggishness | Low | SwiftData manages object faulting. Classification processes one entry at a time. Fetch saves every batch. |

---

## Acceptance Criteria

### M1: Entry Model
- [ ] `isClassified` property exists on Entry with default `false`
- [ ] App builds with zero warnings

### M2: Startup Purge
- [ ] On launch, entries older than 7 days are deleted
- [ ] Purge happens before fetch starts
- [ ] Orphaned StoryGroups are cleaned up

### M3: SyncEngine Progress
- [ ] `fetchedCount` and `totalToFetch` update during sync
- [ ] Values reset to 0 when sync completes
- [ ] New entries are inserted with `isClassified = false`

### M4: ClassificationEngine Polling
- [ ] Classification starts automatically when app launches (not waiting for sync to finish)
- [ ] Polls for unclassified entries every ~2 seconds
- [ ] Sets `isClassified = true` after classifying each entry
- [ ] `classifiedCount` and `totalToClassify` track live progress
- [ ] Yields and saves every 25 entries
- [ ] Cancellable via `stopContinuousClassification()`

### M5: ContentView
- [ ] Status area shows "Fetching n/x" during fetch
- [ ] Status area shows "Categorizing n/x" during classification (below fetch, if concurrent)
- [ ] When both finish, shows "Synced today HH:mm"
- [ ] Only classified entries appear in timeline
- [ ] Articles appear in categories progressively as classification completes
- [ ] UI remains responsive during all background work
- [ ] Manual sync button still works

### M6: Fixtures
- [ ] Preview data has `isClassified = true`
- [ ] UI test demo mode works

---

## Quality Gates and Signoff Checklist

Before implementation:
- [x] Research dossier exists and is marked "sufficient to plan"
- [x] User has approved the approach (polling-based, no migration needed)
- [x] All milestones have acceptance criteria

Before merging:
- [ ] `xcodebuild build` — zero errors, zero warnings
- [ ] Manual test: launch app → see "Fetching n/x" progress → see "Categorizing n/x" appearing while fetch still runs → articles appear in categories as classified
- [ ] Manual test: browse already-classified articles while classification continues — UI is responsive
- [ ] Manual test: no uncategorized articles visible anywhere in UI
- [ ] Manual test: old entries (>7 days) not present after restart
- [ ] Manual test: sync button triggers one-shot sync + classify cycle

---

## Top Delivery Risk

**ClassificationEngine polling architecture (M4)** — this is the most invasive change, converting a one-shot triggered function into a long-lived polling loop. The risk is subtle: the existing `classifyUnclassified()` fetches ALL unclassified entries upfront and iterates through them. The new polling version must handle the changing set (new entries arriving from fetch) gracefully. The recommended approach — re-query on each poll cycle — is safe but must be tested under concurrent load.

## Recommended Next Decision

Approve this plan, then run `/implement` to begin with M1 → M2 → M3 → M4 → M5 → M6 in order.
