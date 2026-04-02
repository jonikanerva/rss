# Research: Status Display Redesign

**Date:** 2026-04-02
**Topic:** Redesign the two-line status display below "News" in the sidebar

---

## 1. Problem

The current status display below "News" in the sidebar shows too many intermediate states and inconsistent text. SyncEngine publishes a free-form `syncProgress: String` that cycles through ~10 different messages ("Syncing feeds...", "Fetching icons...", "Fetching unread articles...", "Loaded N unread articles...", "Checking unread state...", "Fetching new entries...", "History: page N (X new)", etc.). The user wants a clean, predictable two-line display:

- **Line 1 (sync):** Three states only — "Syncing...", "Fetching xxx/yyy", "Synced Today hh:mm"
- **Line 2 (classification):** Two states only — "Categorizing xxx/yyy" (active), hidden (idle)

No other text or status should appear on either line.

---

## 2. Constraints

| Constraint | Detail |
|---|---|
| Max 2 lines | Upper = sync, lower = classification. No third line. |
| MainActor UI | Both engines are `@MainActor @Observable`. Status text is computed in ContentView. |
| No new actors | Two-layer architecture: engines on MainActor, writes via DataWriter. |
| No provider name in classification text | Current impl shows "(Apple FM)" or "(OpenAI GPT-5.4-nano)" — user wants just "Categorizing xxx/yyy". |
| "Synced Today hh:mm" format | Only today's format specified. Need to decide what happens for stale dates (yesterday/older). |
| Line 2 disappears when idle | Classification line must be completely hidden, not empty. |
| Swift 6 strict concurrency | All changes must compile with zero warnings. |

---

## 3. Current Architecture

### 3.1 SyncEngine observable properties (SyncEngine.swift:23-28)

```swift
private(set) var isSyncing = false
private(set) var isFetchingContent = false
private(set) var lastError: String?
private(set) var syncProgress: String = ""     // free-form, set ~10 places
private(set) var fetchedCount: Int = 0
private(set) var totalToFetch: Int = 0
private(set) var lastSyncDate: Date?           // UserDefaults-backed
```

`syncProgress` is set throughout `sync()`, `syncUnread()`, `syncIncremental()`, and `refetchHistory()` with various human-readable messages. ContentView currently shows `syncProgress` first if non-empty, falling back to "Fetching N/X".

### 3.2 ClassificationEngine observable properties (ClassificationEngine.swift:29-33)

```swift
private(set) var isClassifying = false
private(set) var progress: String = ""         // "Categorizing N/X (provider)"
private(set) var classifiedCount = 0
private(set) var totalToClassify = 0
```

### 3.3 ContentView status logic (ContentView.swift:196-214)

```swift
private var fetchStatusText: String? {
  if syncEngine.isSyncing {
    let progress = syncEngine.syncProgress
    if !progress.isEmpty { return progress }          // shows all intermediate text!
    return x > 0 ? "Fetching \(n)/\(x)" : "Syncing..."
  }
  return lastSyncText                                 // "Synced today/yesterday/date HH:mm"
}

private var classifyStatusText: String? {
  guard classificationEngine.isClassifying else { return nil }
  return x > 0 ? "Categorizing \(n)/\(x)" : nil
}
```

### 3.4 UI rendering (ContentView.swift:353-374)

Two optional `Text` views in a `VStack` inside the sidebar section header. Already structured as two separate lines.

### 3.5 Other consumers of engine state

| View | What it uses |
|---|---|
| SettingsView (150-158) | `isSyncing` to disable "Sync Now" button, `lastSyncDate`/`lastError` for display |
| ClassificationSettingsView (101-111) | `isClassifying`, `progress` for reclassify progress |
| CategoryManagementView (156-172) | `isClassifying` to disable button, `progress` in footer |

These views use `isClassifying`, `progress`, `isSyncing` etc. directly — changes to engine properties affect them too.

---

## 4. Alternatives

### Alternative A: Simplify ContentView computed properties only (UI-layer change)

**Approach:** Keep SyncEngine and ClassificationEngine properties as-is. Only change the `fetchStatusText` and `classifyStatusText` computed properties in ContentView to ignore `syncProgress` and use only the numeric counters.

```swift
private var fetchStatusText: String? {
  if syncEngine.isSyncing {
    let n = syncEngine.fetchedCount
    let x = syncEngine.totalToFetch
    return x > 0 ? "Fetching \(n)/\(x)" : "Syncing..."
  }
  return lastSyncText   // "Synced Today hh:mm"
}

private var classifyStatusText: String? {
  guard classificationEngine.isClassifying else { return nil }
  let n = classificationEngine.classifiedCount
  let x = classificationEngine.totalToClassify
  return x > 0 ? "Categorizing \(n)/\(x)" : nil
}
```

**Pros:**
- Minimal change — only ContentView.swift modified
- No impact on SettingsView, ClassificationSettingsView, CategoryManagementView
- SyncEngine keeps its detailed `syncProgress` for logging/debugging and other views

**Cons:**
- `fetchedCount`/`totalToFetch` are only populated during certain sync phases. During "Syncing feeds..." and "Fetching icons..." phases, both are 0, so it shows "Syncing..." — which is the desired behavior.
- During `syncUnread()`, `totalToFetch` is set to `sortedIDs.count` and `fetchedCount` increments as batches complete — but `fetchedCount` tracks *new* entries, not total processed, so the counter may not reach total. However, user specified "xxx kuinka monta haettu", which maps to fetched count.
- During `syncIncremental()`, `totalToFetch = entries.count` but `fetchedCount` is set once at end to `newCount` — no incremental progress.
- `lastSyncText` currently handles today/yesterday/older. Need to simplify to only "Synced Today hh:mm" for today, but what about yesterday? Keep the existing fallback texts for non-today dates.

**Assessment:** Good enough. The numeric counters already exist and are reasonably accurate.

### Alternative B: Introduce SyncPhase enum on SyncEngine

**Approach:** Replace `syncProgress: String` with a typed enum:

```swift
enum SyncPhase: Sendable {
  case idle
  case connecting          // initial setup
  case fetching(done: Int, total: Int)
  case complete(Date)
  case failed(String)
}
```

Update SyncEngine to set `phase` instead of `syncProgress`. ContentView maps enum to display text.

**Pros:**
- Type-safe, no string matching
- Clean separation: engine owns state, view owns presentation
- Other views (Settings) can also use the enum

**Cons:**
- Larger change surface: SyncEngine, ContentView, SettingsView all need updates
- `syncProgress` is also used for internal logging context — would need separate log messages
- Over-engineering for a display-only change
- Other views (Settings, ClassificationSettings) currently use `syncProgress` string and would need migration

**Assessment:** Clean but unnecessary complexity for this task.

### Alternative C: Hybrid — Clean up ContentView + remove `syncProgress` usage from sidebar

**Approach:** Same as Alternative A for the sidebar. Additionally, clean up the `lastSyncText` format. Don't touch SyncEngine internals.

- Remove `syncProgress` from `fetchStatusText` computed property
- Simplify `lastSyncText` to always show "Synced Today hh:mm" when today
- Keep existing "yesterday"/"date" formats for older sync dates (reasonable UX for when app hasn't synced today)
- Remove provider name from `classifyStatusText`

**Pros:**
- Focused change: only ContentView.swift
- No risk to other views that use engine properties
- Achieves all stated requirements

**Cons:**
- None significant

**Assessment:** Best option.

---

## 5. Evidence

### 5.1 Current sync progress flow analysis

| Sync phase | `syncProgress` text | `fetchedCount` | `totalToFetch` |
|---|---|---|---|
| Start | "" | 0 | 0 |
| Syncing feeds | "Syncing feeds..." | 0 | 0 |
| Fetching icons | "Fetching icons..." | 0 | 0 |
| First sync: fetching unread | "Fetching unread articles..." | 0 | N (sorted unread IDs count) |
| First sync: batch loaded | "Loaded X unread articles..." | X (new count) | N |
| First sync: done | "Synced X unread articles" | X | N |
| Incremental: checking | "Checking unread state..." | 0 | 0 |
| Incremental: fetching | "Fetching new entries..." | 0 | N (entries.count) |
| Incremental: done | "Synced X new entries" | X | N |
| After sync | "" | 0 | 0 |

**Key insight:** During the "connecting" phases (feeds, icons), both counters are 0. The proposed "Syncing..." text correctly covers these. Once article fetching begins, `totalToFetch` > 0 and "Fetching xxx/yyy" kicks in automatically.

### 5.2 Incremental sync counter gap

During incremental sync (`syncIncremental`), `totalToFetch` is set once, but `fetchedCount` is only set at the very end (line 194). This means "Fetching 0/N" shows during the fetch, then jumps to "Fetching X/N". This is acceptable because incremental syncs are typically fast (< 2 seconds). For first syncs, the batched approach gives real incremental updates.

### 5.3 Classification provider name

Currently, `ClassificationEngine` sets `progress` to `"Categorizing N/X (providerName)"` at line ~130/201. The user wants just "Categorizing N/X". Since Alternative C only changes ContentView's computed property (using `classifiedCount`/`totalToClassify` directly), the provider name in `progress` string is irrelevant — we don't read it.

### 5.4 Other views impact

- **SettingsView:** Uses `syncEngine.lastSyncDate` and `syncEngine.lastError` — no change needed.
- **ClassificationSettingsView:** Uses `classificationEngine.progress` for reclassify progress — no change needed (different context, reclassify UI can show provider name).
- **CategoryManagementView:** Uses `classificationEngine.isClassifying` and `classificationEngine.progress` — no change needed.

---

## 6. Unknowns

| Unknown | Risk | Mitigation |
|---|---|---|
| What to show when `lastSyncDate` is nil (never synced)? | Low | Show nothing — sync line is hidden until first sync completes. Current behavior. |
| What to show for non-today sync dates? | Low | Keep existing "Synced yesterday hh:mm" and "Synced MMM d hh:mm" formats — user only specified today format but these are reasonable fallbacks. |
| Incremental sync shows "Fetching 0/N" then jumps to "Fetching X/N" | Low | Acceptable — incremental syncs are fast. |
| History refetch shows no sidebar progress | Low | `refetchHistory()` runs after `isSyncing = false` — it's a background task that doesn't show in status. This is correct per requirements. |

**Biggest risk:** The `isFetchingContent` flag (extracted content background fetch) currently doesn't show in the status display, and per requirements it shouldn't. But we need to verify it doesn't accidentally trigger a status line via some code path. Confirmed: `isFetchingContent` is only used in the toolbar ProgressView check (line 383). No risk.

---

## 7. Recommendation

**Evidence is sufficient to plan.** Recommend proceeding with **Alternative C** (hybrid UI-only change):

1. **Modify `fetchStatusText`** in ContentView: remove `syncProgress` usage, use only `isSyncing` + `fetchedCount`/`totalToFetch` counters.
2. **Modify `classifyStatusText`** in ContentView: already correct, just confirm no provider name leaks.
3. **Simplify `lastSyncText`**: keep current format (already matches "Synced Today hh:mm" for today).
4. **No changes to SyncEngine or ClassificationEngine** — their properties serve other views and logging.

Total change: ~10 lines in ContentView.swift. The existing observable properties on both engines already provide exactly the data needed.
