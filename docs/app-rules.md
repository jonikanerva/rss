# App Rules — Feeder

Locked-down behavioral specifications. These rules must never be violated. Any change to this file requires explicit human approval.

---

## Status Display (Sidebar)

The status display is the two-line area below "News" in the sidebar section header. It communicates sync and classification progress to the user.

### Line 1: Sync Status

Exactly three states. No other text may appear on this line.

| State | Text | When |
|---|---|---|
| Connecting | `Syncing...` | `isSyncing == true` and `totalToFetch == 0` |
| Fetching | `Fetching xxx/yyy` | `isSyncing == true` and `totalToFetch > 0` |
| Idle | `Synced today HH:mm` | `isSyncing == false` and `lastSyncDate` is set |

- When `lastSyncDate` is nil (never synced), line 1 is hidden.
- For non-today dates, use "Synced yesterday HH:mm" or "Synced MMM d HH:mm".

### Line 2: Classification Status

Exactly two states. No other text may appear on this line.

| State | Text | When |
|---|---|---|
| Active | `Categorizing xxx/yyy` | `isClassifying == true` and `totalToClassify > 0` |
| Idle | *(hidden)* | `isClassifying == false` |

- Line 2 must be completely hidden when classification is idle — not empty, not a blank line.

### Prohibited Content

The following must **never** appear on either status line:

- Provider names (e.g., "Apple FM", "OpenAI GPT-5.4-nano")
- Sync phase details (e.g., "Syncing feeds...", "Fetching icons...", "Checking unread state...")
- Error messages or failure states
- Article counts, summary text, or any other informational content
- Progress spinners or animations (these belong in the toolbar, not the status text)

### Implementation Contract

- Status text is computed in `SyncStatusView` (defined in `ContentView.swift`) — as computed properties over engine counters.
- `SyncEngine` and `ClassificationEngine` expose raw numeric counters (`fetchedCount`, `totalToFetch`, `classifiedCount`, `totalToClassify`) and boolean flags (`isSyncing`, `isClassifying`).
- The sidebar status display must **never** read `syncProgress` or `progress` strings from the engines.
