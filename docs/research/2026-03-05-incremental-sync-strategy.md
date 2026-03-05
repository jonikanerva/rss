# Research: Incremental Sync Strategy for Fast App Startup

Date: 2026-03-05
Owner: Repository Owner + Agent
Status: Draft

## Problem statement

The current sync implementation fetches all entries from Feedbin on first sync. With ~200k+ articles in a typical long-term Feedbin account, this results in:

- ~2000+ paginated API calls for entries alone (100 per page)
- Additional per-entry HTTP calls for extracted content (Mercury Parser)
- Minutes to hours before the app is usable
- Massive memory and bandwidth consumption for articles the user will never read

The app needs to be **usable within seconds** of first launch, not minutes.

## Current implementation analysis

### Sync flow (SyncEngine.swift)
1. `fetchSubscriptions()` — 1 API call, returns all feeds
2. `fetchAllEntries(since: lastSyncDate)` — auto-paginated, fetches ALL entries when `lastSyncDate` is nil
3. For each new entry: `fetchExtractedContent()` — 1 API call per entry, sequential
4. Deduplication via SwiftData predicate after all entries are in memory
5. Save + update `lastSyncDate`

### Bottlenecks
| Bottleneck | Impact |
|---|---|
| Full entry fetch on first sync | ~2000 API calls, all 200k articles |
| Sequential extracted content fetch | 1 HTTP call per new entry, no parallelism |
| All-or-nothing: app unusable until sync completes | User waits minutes+ |
| No unread-first prioritization | Read articles fetched with same priority as unread |

## Feedbin API capabilities (evidence from API docs)

### Unread entries endpoint
- `GET /v2/unread_entries.json` returns **array of entry IDs only** (not full entries)
- Typically hundreds of IDs, not hundreds of thousands
- Single API call, lightweight response

### Batch entry fetch by IDs
- `GET /v2/entries.json?ids=1,2,3` — max 100 IDs per request
- Returns full entry objects including content
- Allows targeted fetch of specific entries

### Incremental entries
- `GET /v2/entries.json?since=<ISO8601>` — entries created after timestamp
- Already partially used in current implementation via `lastSyncDate`

### Conditional requests (ETags)
- All GET responses include `ETag` and `Last-Modified` headers
- Clients can send `If-None-Match` / `If-Modified-Since` to get `304 Not Modified`
- Reduces bandwidth for unchanged data

### Pagination
- `Link` header with `rel="next"`, `rel="last"` etc.
- `X-Feedbin-Record-Count` header for total record count
- Max 100 entries per page

## Proposed strategy: "Unread First, Recent History, Never Full Backfill"

### Phase 1 — Immediate usability (~5-10 seconds)

1. **Fetch subscriptions** — `GET /v2/subscriptions.json` (1 call)
2. **Fetch unread entry IDs** — `GET /v2/unread_entries.json` (1 call)
3. **Fetch unread entries with content** — `GET /v2/entries.json?ids=...` in batches of 100
   - Typical unread count: 100-1000 entries = 1-10 API calls
4. **Fetch extracted content for unread entries** — parallel via TaskGroup (5-10 concurrent)
5. **Run classification + grouping on unread entries immediately**
6. **App is usable** — user sees categorized unread articles

### Phase 2 — Recent history backfill (background, seconds to minutes)

1. **Fetch recent entries** — `GET /v2/entries.json?since=<7-14 days ago>` with pagination
   - Provides read articles for timeline context
2. **Fetch extracted content** — parallel via TaskGroup
3. **Classification + grouping continue in background** as entries arrive
4. Timeline fills in progressively

### Phase 3 — Ongoing incremental sync

1. Use `since` parameter with persisted `lastSyncDate` (already implemented)
2. Add ETag/If-Modified-Since support for conditional requests
3. Sync unread IDs to detect read-state changes from other clients

### What we never do

- **Never fetch all 200k historical entries** — no user value, massive cost
- **Never block the UI on sync completion** — progressive rendering

## Extracted content optimization

### Current: sequential (O(n) API calls, serial)
```
for entry in entries {
    fetchExtractedContent(entry.extractedContentURL)  // blocking, one at a time
}
```

### Proposed: parallel via TaskGroup (O(n) calls, concurrent)
```
await withTaskGroup(of: ...) { group in
    for entry in entries {
        group.addTask { fetchExtractedContent(entry.url) }
    }
}
```
- Limit concurrency to 5-10 simultaneous requests to avoid overwhelming Feedbin
- Significant wall-clock time reduction

## Unread state sync

The current implementation has `isRead` on Entry but never syncs it from Feedbin. With the unread entries endpoint, we can:

1. Fetch unread IDs on each sync
2. Mark entries as read/unread locally based on Feedbin state
3. This is needed for Phase 1 to work correctly

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Unread entries endpoint returns very large list | Batch processing, same as entries — still far less than 200k |
| Extracted content fetch is slow even with parallelism | Concurrency limit prevents rate limiting; classify with `content` field as fallback while extracted loads |
| User expects full history | Document that only recent history is synced; could add optional "load more" |
| Race condition between Phase 1 and Phase 2 entries | Deduplicate by feedbinEntryID (already unique in SwiftData) |
| `since` date for Phase 2 misses entries created before but updated after | Acceptable for MVP — entries are immutable in practice |

## Alternatives considered

### A. Fetch all entries but stream to UI progressively
- Still ~2000 API calls on first sync
- Better UX but same network cost
- Rejected: too slow, wasteful

### B. Fetch only unread, no history at all
- Fastest possible startup
- But timeline looks empty once articles are read
- Rejected: poor experience for daily use

### C. Use `read=false` parameter on entries endpoint
- `GET /v2/entries.json?read=false` — server-side filter
- Simpler than unread IDs + batch fetch
- But: still paginated, no control over which entries come first
- Also: doesn't give us the list of IDs for read-state sync
- Rejected: unread IDs approach is more flexible

## Evidence and sources

- Feedbin API v2 docs: https://github.com/feedbin/feedbin-api
- Entries API: pagination, `since`, `ids` parameter, max 100 per batch
- Unread entries API: returns array of entry IDs
- Current implementation: `Feeder/FeedbinAPI/FeedbinClient.swift`, `Feeder/FeedbinAPI/SyncEngine.swift`

## Recommendation

Proceed with "Unread First, Recent History, Never Full Backfill" strategy. The core changes are:

1. Add `fetchUnreadEntryIDs()` to FeedbinClient
2. Add `fetchEntriesByIDs(ids:)` to FeedbinClient
3. Restructure SyncEngine.sync() into phased sync (unread first, then recent history)
4. Parallelize extracted content fetching with TaskGroup
5. Sync read/unread state from Feedbin
6. Add ETag support for conditional requests

This transforms first-sync from ~2000+ sequential API calls to ~10 calls before the app is usable.
