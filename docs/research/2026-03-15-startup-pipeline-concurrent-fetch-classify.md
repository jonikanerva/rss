# Research Dossier: App Startup Pipeline — Concurrent Fetch + Classification

**Date**: 2026-03-15
**Status**: Complete — sufficient to plan
**Researcher**: Claude agent

---

## 1. Problem Framing

The Feeder app's current startup pipeline is **sequential**: fetch all articles → classify all → group all. This creates three problems:

1. **No data retention management** — old articles (>7 days) accumulate in SwiftData indefinitely; the 7-day window is only enforced at fetch time.
2. **Wasted wall-clock time** — classification idles while fetch runs, even though it could process already-fetched articles.
3. **Poor user feedback** — status shows "Fetching..." with no progress counts; articles appear uncategorized in the UI before classification runs.

The goal is a **concurrent producer-consumer pipeline** where fetch and classification run in parallel with live progress, while keeping the UI fully responsive and hiding uncategorized articles.

---

## 2. Users and Jobs-to-Be-Done

| User | Job | Current pain |
|------|-----|-------------|
| Daily reader | Open app → see categorized articles immediately | Must wait for full fetch + full classify before articles are properly categorized |
| Dogfood tester | Evaluate "clear and calm" experience | Startup feels slow and status is vague ("Fetching...") |
| Power user | Browse already-loaded articles while new ones sync | UI priority competition with sync/classify work |

---

## 3. Constraints and Assumptions

### Hard constraints (from CLAUDE.md / project rules)
- Swift 6 strict concurrency, complete checking, MainActor default isolation
- No GCD, Combine, completion handlers, continuations, NSLock, semaphores
- SwiftData `@Model` objects never cross actor boundaries
- Structured concurrency only: `async let`, `TaskGroup`, `Task.isCancelled`
- Zero warnings, zero errors after every change

### Assumptions
- Apple Foundation Models availability is checked once at classification start (existing pattern)
- Feedbin API rate limits are not a bottleneck (existing batched fetch handles this)
- Classification is slower than fetching (LLM inference >> network I/O per article)
- SwiftData ModelContext is not thread-safe; all writes to a given context must happen on its owning actor

---

## 4. Alternatives and Tradeoffs

### Alternative A: AsyncStream Producer-Consumer Pipeline

**How it works**: SyncEngine yields `Sendable` DTOs into an `AsyncStream` continuation as articles are fetched. ClassificationEngine consumes the stream via `for await`, classifying each batch as it arrives.

**Pros**:
- True concurrency — classification starts as soon as first article batch arrives
- Built-in backpressure via `.bufferingOldest(n)`
- Clean separation of concerns; each engine owns its own Task
- Continuation is `Sendable`, crosses actor boundaries safely

**Cons**:
- Requires refactoring SyncEngine to yield intermediate results instead of batch-persist-then-signal
- Stream cancellation must be manually wired (consumer cancellation doesn't auto-cancel producer)
- Two ModelContexts needed (one per actor/task), increasing memory and merge complexity
- Classification's "total to classify" count (X) changes as fetch produces more items — requires careful UI state management

**Verdict**: Architecturally clean but high refactor cost. The dual-ModelContext requirement adds complexity.

### Alternative B: Polling with Shared SwiftData Store (Recommended)

**How it works**: SyncEngine persists articles to SwiftData as today, but sets `isClassified = false` on new entries. A separate classification Task polls for unclassified entries at regular intervals (e.g., every 2 seconds or after each fetch batch callback). Both tasks use the same MainActor ModelContext (since both engines are already `@MainActor @Observable`).

**Pros**:
- Minimal refactor — SyncEngine keeps its current persist-in-batches pattern
- Single ModelContext, no merge conflicts
- Classification "discovers" new work naturally via SwiftData queries
- Progress counts derive directly from SwiftData state (count of `isClassified == false`)
- Fits existing `@MainActor @Observable` architecture

**Cons**:
- Polling introduces small latency (up to poll interval) before classification starts on new articles
- Both engines share MainActor for state mutations (but actual heavy work is offloaded to `.utility` tasks)
- Slightly less elegant than a pure stream pipeline

**Verdict**: Pragmatic, low-risk, fits existing architecture. Polling latency is negligible (1–2 seconds) compared to classification time per article.

### Alternative C: Notification-Based Trigger

**How it works**: SyncEngine calls a callback/delegate method after each batch persist. ClassificationEngine subscribes and processes each batch.

**Pros**:
- Zero latency between fetch and classify
- No polling overhead

**Cons**:
- In Swift 6 strict concurrency, closures crossing actor boundaries require careful `@Sendable` handling
- Tighter coupling between engines
- Callback patterns can become complex with cancellation and error handling

**Verdict**: Possible but adds coupling. The benefit over polling is marginal given classification's per-article latency.

---

## 5. Evidence

### 5.1 SwiftData Batch Delete

`modelContext.delete(model: Entry.self, where: predicate)` performs SQL-level batch deletion without materializing objects. Critical: **must call `save()` immediately after delete and before any inserts** to avoid accidentally deleting freshly inserted records.

- Source: [Apple Documentation — delete(model:where:includeSubclasses:)](https://developer.apple.com/documentation/swiftdata/modelcontext/delete(model:where:includesubclasses:))
- Source: [Fatbobman — How to Batch Delete Data in SwiftData](https://fatbobman.com/en/snippet/how-to-batch-delete-data-in-swiftdata/)

### 5.2 @Query Predicate Limitations

Array property predicates (`categoryLabels.isEmpty`) are unreliable in SwiftData — known crashes with `EXC_BAD_ACCESS`. **Boolean flag fields are the safe, indexable alternative**.

- Source: [Apple Developer Forums — SwiftData query filter on array](https://developer.apple.com/forums/thread/743150)
- Source: [Hacking with Swift — Common SwiftData errors](https://www.hackingwithswift.com/quick-start/swiftdata/common-swiftdata-errors-and-their-solutions)

**Recommendation**: Add `isClassified: Bool = false` to the Entry model. Set to `true` after successful classification. Use `#Predicate<Entry> { $0.isClassified }` for UI queries.

### 5.3 Task Priority

| Priority | QoS | Use case | Starvation risk |
|----------|-----|----------|-----------------|
| `.utility` | Low (17) | User-visible long work | Low |
| `.background` | Background (9) | Invisible maintenance | High under load |

`.utility` is correct for both fetch and classify — both are user-visible (progress indicators shown). `.background` should only be used for truly invisible work like old-article pruning.

- Source: [Apple — TaskPriority](https://developer.apple.com/documentation/swift/taskpriority)
- Source: [SE-0304 — Structured Concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)

### 5.4 Progress Updates Across Actors

The sanctioned pattern: `@Observable @MainActor` class with progress properties, updated from background via `await MainActor.run { }`. **Batch updates** (every N items or every 0.5s) to avoid excessive actor hops and UI churn.

- Source: [SwiftLee — MainActor usage](https://www.avanderlee.com/swift/mainactor-dispatch-main-thread/)
- Source: [Donny Wals — Concurrency changes in Swift 6.2](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)

### 5.5 Current Codebase State

| Component | Current behavior | Required change |
|-----------|-----------------|-----------------|
| SyncEngine.sync() | Sets `isSyncing` bool, shows "Fetching..." | Add `fetchedCount`/`totalToFetch` counters, update per batch |
| SyncEngine.syncUnread() | Fetches batches of 100, persists incrementally | Already incremental — add progress counter updates |
| ClassificationEngine | Triggers only after sync completes via onChange | Launch as parallel Task on app startup, poll for unclassified entries |
| Entry model | No `isClassified` field | Add `isClassified: Bool = false` |
| ContentView statusText | Single line, boolean-based | Two lines: "Fetching n/x" + "Categorizing n/x" |
| ContentView @Query | No classification filter | Add `isClassified == true` predicate |
| Startup | No old-article cleanup | Add batch delete of entries older than 7 days |

---

## 6. Unknowns and Risk Flags

| # | Unknown | Impact | Mitigation |
|---|---------|--------|-----------|
| 1 | **SwiftData migration** — adding `isClassified` field requires a lightweight migration. Will SwiftData auto-migrate with a default value? | High — migration failure = data loss or crash | Test with existing database. SwiftData should auto-migrate for additive fields with defaults, but must verify. |
| 2 | **Classification throughput** — how many articles/minute can Apple FM classify? If much slower than fetch, the "Categorizing" counter will lag far behind. | Medium — UX perception of slowness | Already observed in dogfood. Consider batch-parallel classification if needed. |
| 3 | **ModelContext contention** — both engines writing to same MainActor ModelContext. Could save() calls from one engine interfere with the other? | Medium — potential data inconsistency | Both engines are `@MainActor`, so writes are serialized. The risk is low but should be tested under load. |
| 4 | **Existing articles** — first launch after this change: existing articles lack `isClassified` field. Do they disappear from UI until re-classified? | High — all articles vanish on first launch | Migration must set `isClassified = true` for all entries that already have `categoryLabels`. |
| 5 | **Total-to-fetch count** — Feedbin API doesn't return total entry count upfront for unread-first sync. The "x" in "Fetching n/x" may not be known. | Medium — can't show "n/x" if x is unknown | For initial sync, show "Fetching n..." (no total). For incremental sync, total is known from `since` query. Alternatively, fetch unread IDs first (already done) — count of IDs = total. |

---

## 7. Stance and Recommendations

### Evidence sufficiency
**Sufficient to plan.** All five research questions have clear, evidence-backed answers. The recommended approach (Alternative B: polling with shared store) fits the existing architecture with minimal risk.

### Single most critical unknown
**#4: Existing article migration.** If `isClassified` defaults to `false` and we filter UI on `isClassified == true`, every existing article disappears on first launch. The migration logic must handle this explicitly.

### Recommended next action
Proceed to `/plan` with Alternative B (polling-based concurrent pipeline) as the chosen approach. The plan should detail:
1. Entry model migration (add `isClassified`, backfill existing data)
2. Startup cleanup (batch delete >7 days)
3. SyncEngine progress counters
4. ClassificationEngine as independent polling Task
5. ContentView status UI (two-line progress)
6. @Query predicate for hiding uncategorized entries
