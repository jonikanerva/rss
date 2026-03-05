# Plan: Incremental Sync Strategy for Fast App Startup

Date: 2026-03-05
Owner: Repository Owner + Agent
Status: Draft
Research: `docs/research/2026-03-05-incremental-sync-strategy.md`

## Objective

Transform first-sync from ~2000+ sequential API calls (minutes+) to ~10 calls before app is usable (seconds). Ongoing syncs become lightweight incremental updates.

## Acceptance criteria

1. App shows categorized unread articles within ~10 seconds of first sync start.
2. Recent history (7-14 days) fills in progressively in background.
3. Extracted content is fetched in parallel, not sequentially.
4. Read/unread state syncs from Feedbin.
5. Full 200k historical backfill never happens.
6. Zero Swift 6 concurrency warnings/errors.
7. Existing incremental sync (`since` + `lastSyncDate`) continues to work.

## Implementation steps

### Step 1: Add new FeedbinClient endpoints

File: `Feeder/FeedbinAPI/FeedbinClient.swift`

Add three new methods:

```swift
/// Fetch all unread entry IDs.
/// GET /v2/unread_entries.json -> [Int]
func fetchUnreadEntryIDs() async throws -> [Int]

/// Fetch entries by specific IDs, in batches of 100.
/// GET /v2/entries.json?ids=1,2,3
func fetchEntriesByIDs(_ ids: [Int]) async throws -> [FeedbinEntry]

/// Fetch extracted content for multiple entries in parallel.
/// Uses TaskGroup with concurrency limit.
func fetchExtractedContentBatch(entries: [(id: Int, url: String)]) async -> [(id: Int, content: FeedbinExtractedContent?)]
```

No changes to existing methods — they remain available for incremental sync.

### Step 2: Restructure SyncEngine into phased sync

File: `Feeder/FeedbinAPI/SyncEngine.swift`

Replace the single `sync()` method with a phased approach:

```
sync()
  ├── Phase 1: syncUnread()        — immediate usability
  │   ├── fetchSubscriptions()
  │   ├── syncFeeds()
  │   ├── fetchUnreadEntryIDs()
  │   ├── fetchEntriesByIDs()      — batches of 100
  │   ├── fetchExtractedContentBatch()  — parallel
  │   └── persist + classify + group
  │
  └── Phase 2: syncRecentHistory() — background backfill
      ├── fetchEntries(since: 14 days ago)  — paginated
      ├── fetchExtractedContentBatch()      — parallel
      └── persist + classify + group (progressive)
```

Key behaviors:
- Phase 1 completes before Phase 2 starts.
- After Phase 1, set a flag/signal so UI knows articles are ready.
- Phase 2 runs as a background Task, does not block UI.
- Both phases deduplicate via existing `feedbinEntryID` unique constraint.
- `lastSyncDate` is updated after both phases complete.

### Step 3: Parallel extracted content fetching

Replace the current sequential per-entry fetch in `syncEntries()` with a TaskGroup-based parallel fetch.

```swift
await withTaskGroup(of: (Int, FeedbinExtractedContent?).self) { group in
    var active = 0
    for entry in entriesNeedingContent {
        if active >= 8 { // concurrency limit
            _ = await group.next()
            active -= 1
        }
        group.addTask {
            let content = try? await client.fetchExtractedContent(from: entry.url)
            return (entry.id, content)
        }
        active += 1
    }
    for await (id, content) in group {
        // apply content to entry
    }
}
```

Concurrency limit of 8 balances speed vs. server pressure.

### Step 4: Sync read/unread state

In Phase 1, after fetching unread IDs:
- Entries fetched via unread IDs are marked `isRead = false`.
- In Phase 2 (recent history), entries NOT in unread ID set are marked `isRead = true`.

This gives accurate read state from Feedbin on every sync.

### Step 5: Update ongoing incremental sync

Modify the periodic sync (already called via `startPeriodicSync`) to:
1. Fetch subscriptions (existing).
2. Fetch unread IDs — diff against local to update read state.
3. Fetch new entries via `since` + `lastSyncDate` (existing).
4. Fetch extracted content in parallel for new entries.
5. Classify + group new entries.

This keeps periodic syncs lightweight.

### Step 6: Progress reporting

Update `syncProgress` to reflect phases:
- "Syncing feeds..."
- "Fetching unread articles..."
- "Processing 347 unread articles..."
- "Ready. Loading recent history..."
- "Background: processing history (page 3)..."

## Files changed

| File | Change |
|---|---|
| `Feeder/FeedbinAPI/FeedbinClient.swift` | Add `fetchUnreadEntryIDs()`, `fetchEntriesByIDs()` |
| `Feeder/FeedbinAPI/FeedbinModels.swift` | No changes expected |
| `Feeder/FeedbinAPI/SyncEngine.swift` | Restructure `sync()` into phased approach, parallel content fetch, read-state sync |

## Dependencies

- No new dependencies. Uses existing URLSession, SwiftData, TaskGroup.
- Classification and grouping engines are called after each phase (existing code).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Feedbin rate limits parallel content fetches | Low | Medium | Concurrency limit of 8; back off on 429 |
| Unread list is very large (10k+) | Low | Low | Still batched at 100; 100 calls is far better than 2000 |
| Phase 2 overlaps with Phase 1 entries | Certain | None | SwiftData unique constraint handles dedup |
| Classification blocks UI during Phase 1 | Medium | Medium | Classification already runs async; ensure it doesn't block sync completion signal |

## Verification

```bash
# Build must pass with zero errors/warnings
xcodebuild -project Feeder.xcodeproj -scheme Feeder -configuration Debug build 2>&1 | grep -E "(error:|warning:)"

# Manual verification
# 1. Delete app data (fresh install scenario)
# 2. Launch app, authenticate with Feedbin
# 3. Observe: unread articles appear within ~10 seconds
# 4. Observe: recent history fills in progressively after
# 5. Observe: classification runs on articles as they arrive
# 6. Check Console.app logs for sync phase progression
```

## Rollback

All changes are in `FeedbinClient.swift` and `SyncEngine.swift`. Revert the PR to restore previous full-fetch behavior.
