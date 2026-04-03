# Execution Log: UI Performance & Visual Polish

Date: 2026-04-02
Plan: `docs/plans/2026-04-02-ui-perf-and-polish-plan.md`
Branch: `feat/ui-perf-polish`

---

## M0: Baseline Measurement & Instrumentation

### Step 0.1: Thread affinity assertions
- Added `#if DEBUG assert(!Thread.isMainThread)` to 5 DataWriter methods
- Files: `DataWriter.swift`

### Step 0.2: Body evaluation counters
- Added `_printChanges()` to EntryRowView and EntryListView (later removed in M3)
- Files: `EntryRowView.swift`, `ContentView.swift`

### Step 0.3: Scroll performance test
- Added `testScrollPerformance()` using `XCTClockMetric` with 10× fast swipe
- File: `FeederUITests.swift`

**Commit**: `7a3bc1c` — `chore(perf): add baseline measurement instrumentation`

---

## M1: Performance Fixes

### Step 1.1: Pre-compute summary plain text
- Added `summaryPlainText: String = ""` to Entry model
- Compute in both `persistEntries()` overloads and seed data
- EntryRowView now reads pre-computed field instead of running regex

### Step 1.2: Replace AsyncImage with cached favicon data
- Added `faviconData: Data?` to Feed model
- Changed `syncIcons()` from `throws` to `async throws` — downloads favicon bytes at sync time
- Replaced `AsyncImage` with `Image(nsImage: NSImage(data:))` — zero network during scroll
- Fallback initials use `.secondary` color instead of accent

### Step 1.3: Throttle @Observable progress updates
- ClassificationEngine: throttled `classifiedCount`/`progress` updates to 200ms intervals
- SyncEngine: throttled `fetchedCount` updates to 200ms intervals

### Step 1.4: Isolate status display
- Extracted `SyncStatusView` with its own `@Environment` reads for both engines
- ContentView no longer reads high-frequency counter properties
- Engine counter changes only invalidate the small status text view, not the entire list

### Schema change
- Bumped `currentSchemaVersion` 12 → 13 (triggers fresh sync on next launch)

**Commit**: `a3a2b2b` — `perf: pre-compute summary, cache favicons, throttle progress, isolate status`

---

## M2: Visual Polish

### Step 2.1: Mute accent color, feed names
- `domainPillColor`: `#E8654A` → `Color(nsColor: .secondaryLabelColor)`
- Feed name: removed `.uppercased()` — natural case from Feed.title
- Section headers: "TODAY" → "Today", "YESTERDAY" → "Yesterday", no `.uppercased()`

### Step 2.2: Detail panel metadata
- Date: removed `.uppercased()` — "Friday 2. April 2026 at 14.30"
- Author: removed `.uppercased()` — natural case
- Domain: changed to `.lowercased()`
- Added favicon + domain/author HStack layout in article header
- CSS: `.date` color → `--text-secondary`, `text-transform: none`
- CSS: `.author` color → `--text-secondary`, `text-transform: none`
- CSS: `.domain` `text-transform: lowercase`
- ArticleWebView: removed `.uppercased()` on domain

### Step 2.3: Native selection
- Removed custom `listRowBackground` with `RoundedRectangle`
- Removed `.scrollContentBackground(.hidden)`
- Removed dead `listSelectionColor` from FontTheme

### Step 2.4: Animations
- Added `.animation(.easeInOut(duration: 0.2))` for filter/category transitions
- Added `.animation(.easeInOut(duration: 0.25))` for reader/web mode switch
- Added `.contentTransition(.numericText())` for progress counters
- All animations respect `accessibilityReduceMotion`

### Step 2.5: CSS palette
- Accent: `#E8654A` → `#C0463A` (muted red)
- Links: `#E8654A` → `#4A90D9` (standard blue)
- Dark mode bg: `#1d1d1f` → `#1E1E1E` (explicit)

**Commit**: `8b99a6d` — `style: visual polish — muted colors, native selection, animations, no ALL CAPS`

---

## M3: Final Verification & Cleanup

### Step 3.1: Full test suite
- `make test-all`: **ALL 7 TESTS PASSED**, zero failures, zero warnings

### Step 3.3: Remove debug instrumentation
- Removed `_printChanges()` from EntryRowView and EntryListView
- Kept DataWriter thread assertions for ongoing safety

**Commit**: `1e43a17` — `chore(cleanup): remove debug instrumentation`

---

## Quality Gate Checklist

- [x] `make test-all` passes (7/7 tests green)
- [x] No `AsyncImage` in codebase
- [x] No `.uppercased()` in view rendering (except single-letter favicon fallback)
- [x] No `stripHTMLToPlainText` called during rendering
- [x] Thread assertions in DataWriter (ongoing)
- [x] `_printChanges()` debug instrumentation removed
- [x] All animations respect `accessibilityReduceMotion`
- [x] Schema version bumped (12 → 13)
- [x] CSS dark mode updated
