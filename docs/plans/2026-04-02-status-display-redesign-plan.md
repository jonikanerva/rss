# Plan: Status Display Redesign

**Date:** 2026-04-02
**Research:** [docs/research/2026-04-02-status-display-redesign.md](../research/2026-04-02-status-display-redesign.md)
**Approach:** Alternative C — UI-layer only change in ContentView.swift

---

## 1. Scope

Simplify the two-line status display below "News" in the sidebar to show exactly:

- **Line 1 (sync):** "Syncing..." → "Fetching xxx/yyy" → "Synced Today hh:mm"
- **Line 2 (classification):** "Categorizing xxx/yyy" (active) or hidden (idle)

No other text or status on either line. No changes to SyncEngine or ClassificationEngine.

**Single file changed:** `Feeder/Views/ContentView.swift` (~10 lines modified)

---

## 2. Milestones

### M1: Simplify `fetchStatusText` computed property

**File:** ContentView.swift, lines 196-207

**Change:** Remove `syncProgress` string usage. Use only boolean `isSyncing` + numeric counters `fetchedCount`/`totalToFetch`.

**Before:**
```swift
private var fetchStatusText: String? {
  if syncEngine.isSyncing {
    let progress = syncEngine.syncProgress
    if !progress.isEmpty {
      return progress
    }
    let n = syncEngine.fetchedCount
    let x = syncEngine.totalToFetch
    return x > 0 ? "Fetching \(n)/\(x)" : "Syncing..."
  }
  return lastSyncText
}
```

**After:**
```swift
private var fetchStatusText: String? {
  if syncEngine.isSyncing {
    let n = syncEngine.fetchedCount
    let x = syncEngine.totalToFetch
    return x > 0 ? "Fetching \(n)/\(x)" : "Syncing..."
  }
  return lastSyncText
}
```

**Acceptance criteria:**
- During sync with no article count yet → shows "Syncing..."
- During sync with article counts → shows "Fetching xxx/yyy"
- After sync → shows "Synced today hh:mm" (or yesterday/date variants)
- No `syncProgress` free-form text ever appears in sidebar

**Confidence:** High

### M2: Verify `classifyStatusText` computed property

**File:** ContentView.swift, lines 209-214

**Current code already correct:**
```swift
private var classifyStatusText: String? {
  guard classificationEngine.isClassifying else { return nil }
  let n = classificationEngine.classifiedCount
  let x = classificationEngine.totalToClassify
  return x > 0 ? "Categorizing \(n)/\(x)" : nil
}
```

This already uses numeric counters directly (no `progress` string, no provider name). No code change needed — just verify.

**Acceptance criteria:**
- During classification → shows "Categorizing xxx/yyy"
- When idle → line completely hidden (returns nil)
- No provider name ("Apple FM", "OpenAI...") appears

**Confidence:** High

### M3: Verify `lastSyncText` format

**File:** ContentView.swift, lines 183-194

**Current code already matches requirements:**
```swift
private var lastSyncText: String? {
  guard let date = syncEngine.lastSyncDate else { return nil }
  let calendar = Calendar.current
  let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  if calendar.isDateInToday(date) {
    return "Synced today \(time)"
  } else if calendar.isDateInYesterday(date) {
    return "Synced yesterday \(time)"
  } else {
    return "Synced \(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
  }
}
```

User specified "Synced Today hh:mm" — current code shows "Synced today hh:mm" (lowercase "today"). The yesterday/older formats are reasonable fallbacks. No change needed unless user wants capitalized "Today".

**Acceptance criteria:**
- Today → "Synced today HH:mm"
- Yesterday → "Synced yesterday HH:mm"
- Older → "Synced MMM d HH:mm"
- Never synced → line hidden (nil)

**Confidence:** High

### M4: Create `docs/app-rules.md` with status display spec

**New file:** `docs/app-rules.md`

Create a new "app fundamentals" document for rules that must never be broken. This is the place for locked-down behavioral specs — not code style (that's `swift-code-rules.md`), not architecture (that's `CLAUDE.md`), but concrete app behavior contracts.

**Initial content — Status Display section:**

- The status display is the two-line area below "News" in the sidebar
- **Line 1 (sync):** Exactly three states — "Syncing...", "Fetching xxx/yyy", "Synced today hh:mm"
- **Line 2 (classification):** Exactly two states — "Categorizing xxx/yyy" (active), hidden (idle)
- No other text, status, or information may appear on either line
- Status text is computed in ContentView only — engines expose raw counters, not display strings
- Never show provider names, phase details, error messages, or intermediate sync step descriptions in the sidebar status

**Integration points:**

1. **CLAUDE.md** — add one-line reference: `App behavior rules: docs/app-rules.md`
2. **`.claude/skills/codereview/skill.md`** — add to review checklist: read `docs/app-rules.md` and verify changes don't violate any app rules

**Acceptance criteria:**
- `docs/app-rules.md` exists with prescriptive ("must", "never") status display spec
- CLAUDE.md references it so agents discover it during normal work
- Codereview skill reads it as part of every review
- Future app behavior rules can be added to the same file

**Confidence:** High

### M5: Build verification

Run `make build` and verify zero errors and zero warnings.

**Confidence:** High (removing 4 lines from a computed property cannot introduce build issues)

---

## 3. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Incremental sync shows "Fetching 0/N" briefly | Medium | Low | Acceptable — incremental syncs are fast (< 2s). No fix needed. |
| Other views break | None | N/A | No engine properties changed. SettingsView, ClassificationSettingsView, CategoryManagementView unaffected. |
| `lastSyncText` format mismatch | Low | Low | User said "Synced Today hh:mm" — current code says "Synced today" (lowercase). Clarify with user if needed. |

---

## 4. Confidence

| Milestone | Confidence | Reason |
|---|---|---|
| M1: Simplify fetchStatusText | High | Removing 4 lines from a computed property |
| M2: Verify classifyStatusText | High | No change needed — already correct |
| M3: Verify lastSyncText | High | No change needed — already correct |
| M4: Create docs/app-rules.md + integrate | High | New file + two one-line additions |
| M5: Build verification | High | Trivial change, no new code paths |

**Overall: High** — this is a 4-line deletion + documentation.

---

## 5. Quality Gates

- [ ] `make build` passes with zero errors and zero warnings
- [ ] `make test` passes (if applicable tests exist)
- [ ] Manual verification: sync triggers "Syncing..." then "Fetching N/X" then "Synced today HH:mm"
- [ ] Manual verification: classification shows "Categorizing N/X" then disappears
- [ ] Manual verification: no other text appears on either status line
- [ ] No changes to SyncEngine.swift, ClassificationEngine.swift, or any other file
- [ ] `docs/app-rules.md` exists with prescriptive status display spec
- [ ] CLAUDE.md references `docs/app-rules.md`
- [ ] Codereview skill reads `docs/app-rules.md` as part of every review
