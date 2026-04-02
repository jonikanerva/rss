# Plan: UI Performance & Visual Polish

Date: 2026-04-02
Research: `docs/research/2026-04-02-ui-perf-and-polish.md`
Branch: `feat/ui-perf-polish`
Status: Draft — awaiting approval

---

## 1. Scope

### What
Fix scroll jank in the article list during sync/classification, and apply visual polish: muted color palette, native selection, subtle animations, and proper text casing (no ALL CAPS).

### Why
The article list stutters every time sync or classification runs — which is every launch and every periodic refresh. The visual issues (bright orange accent overuse, custom selection override, ALL CAPS text) make the app feel unpolished compared to reference apps like Feedbin.

### Not in scope
- Category model redesign (item #6 in NEXT-ACTIONS)
- Test suite quality improvements (item #4)
- Any changes to sync/classification logic beyond throttling progress updates
- Reader pane light background (deferred — needs CSS dual-mode work)

---

## 2. Milestones

### M0: Baseline Measurement & Instrumentation

**Goal**: Establish numeric before-state so we can objectively verify improvements.

#### Step 0.1: Thread affinity assertion in DataWriter

**File**: `Feeder/DataWriter.swift`

Add `#if DEBUG` assertion at the top of key methods to verify DataWriter runs off MainActor:

```swift
#if DEBUG
func persistEntries(_ entries: [FeedbinEntry], markAsRead: Bool) throws -> Int {
    assert(!Thread.isMainThread, "DataWriter.persistEntries must not run on main thread")
    // ... existing code
}
#endif
```

Add to: `persistEntries` (both overloads), `applyClassification`, `updateReadState`, `syncIcons`.

**Acceptance**: App launches in Debug, assertions do not fire → DataWriter is correctly off main thread. If assertions fire → critical fix needed before proceeding (see Risk #1).

#### Step 0.2: Body evaluation counter (debug only)

**File**: `Feeder/Views/EntryRowView.swift`, `Feeder/Views/ContentView.swift`

Add `_printChanges()` to `EntryRowView.body` and `EntryListView.body` behind `#if DEBUG`:

```swift
#if DEBUG
let _ = Self._printChanges()
#endif
```

**Acceptance**: Console shows which properties trigger re-renders during sync. Record baseline count for a full sync cycle.

#### Step 0.3: Scroll performance UI test

**File**: `FeederUITests/FeederUITests.swift`

Add `testScrollPerformance()` using `XCTClockMetric` — scroll the article list 10× up/down at fast velocity with demo data. Record baseline duration.

**Acceptance**: Test runs and produces repeatable numbers (±10% variance across runs).

**Commit checkpoint**: `chore(perf): add baseline measurement instrumentation`

---

### M1: Performance Fixes

**Goal**: Eliminate the primary causes of scroll jank. Apply fixes in priority order, measuring after each.

#### Step 1.1: Pre-compute summary plain text at persist time

**Files**:
- `Feeder/Models/Entry.swift` — add `var summaryPlainText: String = ""`
- `Feeder/FeederApp.swift` — bump `currentSchemaVersion` from 12 → 13
- `Feeder/DataWriter.swift` — compute `summaryPlainText` in both `persistEntries()` overloads
- `Feeder/Views/EntryRowView.swift` — replace runtime `stripHTMLToPlainText` with pre-computed field

**Entry model change** (line ~32):
```swift
/// Pre-stripped summary plain text (computed at persist time, used by row view)
var summaryPlainText: String = ""
```

**DataWriter change** — in both `persistEntries()` methods, after line 206/252:
```swift
entry.summaryPlainText = stripHTMLToPlainText(dto.summary ?? "")
```

**EntryRowView change** — replace `summaryText` computed property (lines 25-29):
```swift
private var summaryText: String {
    let summary = entry.summaryPlainText
    return summary.isEmpty ? entry.plainText : summary
}
```

**Acceptance**: `stripHTMLToPlainText` is never called during rendering. Zero regex during scroll.

**Commit checkpoint**: `perf(views): pre-compute summary plain text at persist time`

#### Step 1.2: Replace AsyncImage with in-memory favicon cache

**Files**:
- `Feeder/Models/Feed.swift` — add `var faviconData: Data?` field
- `Feeder/FeederApp.swift` — schema version already bumped in 1.1 (or bump to 14 if separate)
- `Feeder/DataWriter.swift` — download favicon bytes in `syncIcons()`, store as `Data`
- `Feeder/Views/EntryRowView.swift` — replace `AsyncImage` with `Image(nsImage:)`

**Approach**: Download favicon data at sync time in DataWriter (background). Store raw bytes on the Feed model. Render with `NSImage(data:)` → `Image(nsImage:)` — zero network, zero decode during scroll.

**Feed model change**:
```swift
/// Favicon image data — downloaded at sync time, rendered directly in list rows
var faviconData: Data?
```

**DataWriter.syncIcons change** — after setting `feed.faviconURL`, also download the bytes:
```swift
if let iconURL = iconsByHost[lookupHost] ?? iconsByHost[host] {
    if feed.faviconURL != iconURL {
        feed.faviconURL = iconURL
        // Download favicon data for offline rendering
        if let url = URL(string: iconURL),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            feed.faviconData = data
        }
    }
}
```

Note: `syncIcons` is currently synchronous (`throws`). It needs to become `async throws` to support `URLSession.data(from:)`. Update the call site in `SyncEngine.sync()` accordingly.

**FaviconView rewrite** (EntryRowView.swift):
```swift
struct FaviconView: View {
    let feed: Feed?

    private var fallbackLetter: String {
        guard let title = feed?.title, let first = title.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        if let data = feed?.faviconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            initialsIcon
        }
    }

    private var initialsIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
            Text(fallbackLetter)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}
```

**Acceptance**: No `AsyncImage` in the codebase. Favicon displays without network during scroll. Fallback initials shown for feeds without favicon data.

**Commit checkpoint**: `perf(views): replace AsyncImage with pre-cached favicon data`

#### Step 1.3: Throttle @Observable progress updates

**Files**:
- `Feeder/Classification/ClassificationEngine.swift` — throttle `classifiedCount` updates
- `Feeder/FeedbinAPI/SyncEngine.swift` — throttle `fetchedCount` updates

**Approach**: Gate progress counter updates to fire at most once per 200ms using a simple time check:

```swift
// ClassificationEngine — add private property:
private var lastProgressUpdate: ContinuousClock.Instant = .now

// In classification loop, replace direct classifiedCount += 1:
let now = ContinuousClock.now
if now - lastProgressUpdate >= .milliseconds(200) || index == inputs.count - 1 {
    classifiedCount = index + 1
    lastProgressUpdate = now
}
```

Same pattern for SyncEngine `fetchedCount` updates.

**Acceptance**: During a 1000-article classification, `classifiedCount` changes ~25 times (every 200ms) instead of 1000 times. UI still shows smooth progress.

**Commit checkpoint**: `perf(engines): throttle progress counter updates to 200ms`

#### Step 1.4: Isolate status display from article list

**Files**:
- `Feeder/Views/ContentView.swift` — extract status text into a separate `SyncStatusView`

**Problem**: `ContentView` reads `syncEngine.fetchedCount` and `classificationEngine.classifiedCount` via computed properties. When these change, the entire `ContentView.body` re-evaluates, including `EntryListView`.

**Approach**: Extract the sidebar section header (lines 349-369) into a standalone `SyncStatusView` that reads the engines directly. `ContentView.body` no longer reads engine progress properties → engine counter changes don't invalidate `EntryListView`.

```swift
struct SyncStatusView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ClassificationEngine.self) private var classificationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("News")
                .font(.system(size: FontTheme.sectionHeaderSize, weight: .bold))
                .foregroundStyle(.primary)
                .textCase(nil)

            if let fetchStatus = fetchStatusText {
                Text(fetchStatus)
                    .font(.system(size: FontTheme.statusSize))
                    .foregroundStyle(.tertiary)
                    .textCase(nil)
            }
            if let classifyStatus = classifyStatusText {
                Text(classifyStatus)
                    .font(.system(size: FontTheme.statusSize))
                    .foregroundStyle(.tertiary)
                    .textCase(nil)
            }
        }
        .padding(.bottom, 4)
    }

    // Move fetchStatusText and classifyStatusText here
    // Also move lastSyncText here
}
```

**ContentView changes**:
- Remove `fetchStatusText`, `classifyStatusText`, `lastSyncText` computed properties
- Replace inline sidebar header VStack with `SyncStatusView()`
- ContentView still reads `syncEngine.isSyncing` for toolbar button → this is fine, it's a boolean toggle not a high-frequency counter
- Move `syncEngine.lastSyncDate` reading to SyncStatusView

**Acceptance**: `_printChanges()` on `EntryListView` shows zero re-evaluations when sync/classification counters change. Only status text re-renders.

**Commit checkpoint**: `perf(views): isolate sync status display from article list`

#### Step 1.5: Post-M1 measurement

Re-run the same measurements from M0:
- `_printChanges()` body evaluation count during full sync
- `testScrollPerformance()` duration
- Manual scroll feel assessment

**Acceptance**: Measurable improvement in at least one metric. Target: ≥50% reduction in EntryRowView body evaluations during sync.

---

### M2: Visual Polish

**Goal**: Align the app's visual presentation with macOS conventions and the Feedbin reference palette.

#### Step 2.1: Mute accent color, update feed name styling

**Files**:
- `Feeder/Views/FontTheme.swift` — change `domainPillColor` from `#E8654A` to muted gray
- `Feeder/Views/EntryRowView.swift` — feed name: remove `.uppercased()`, apply Title Case
- `Feeder/Views/ContentView.swift` — section labels: remove `.uppercased()`, apply Title Case

**FontTheme change**:
```swift
// Before: Color(hex: 0xE8654A) — bright orange
// After: muted gray matching Feedbin reference
static let domainPillColor = Color(nsColor: .secondaryLabelColor)
```

Keep `#E8654A` available as `accentColor` for interactive elements (links, category tags) if needed later — but remove from feed names, dates, and author lines.

**EntryRowView feed name** (line 43):
```swift
// Before: Text(feedName.uppercased())
Text(feedName)  // Title as-is from Feed.title (already proper case)
```

**ContentView section label** — rewrite `sectionLabel(for:)` (lines 42-55):
```swift
private func sectionLabel(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return "Today"
    } else if calendar.isDateInYesterday(date) {
        return "Yesterday"
    } else {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let day = calendar.component(.day, from: date)
        let month = date.formatted(.dateTime.month(.wide))
        let year = date.formatted(.dateTime.year())
        return "\(weekday) \(day). \(month) \(year)"
    }
}
```

**Acceptance**: No `.uppercased()` calls in view rendering code (except the single-letter favicon fallback). Feed names render in natural case. Section headers in Title Case.

**Commit checkpoint**: `style(views): mute accent color, remove ALL CAPS from feed names and headers`

#### Step 2.2: Fix metadata display in detail panel

**Files**:
- `Feeder/Views/EntryDetailView.swift` — remove ALL CAPS from author, domain, date
- `Feeder/Views/EntryDetailView.swift` — add favicon + domain/author layout
- `Feeder/Resources/article-style.css` — update `.author` and `.domain` text-transform
- `Feeder/Views/ArticleWebView.swift` — remove `.uppercased()` on domain

**EntryDetailView.articleHeader changes**:

Date formatting — rewrite `DetailDateFormatting.formatDate`:
```swift
static func formatDate(_ date: Date) -> String {
    let dateStr = dateFormatter.string(from: date)
    let timeStr = timeFormatter.string(from: date)
    return "\(dateStr) at \(timeStr)"  // Title Case, no .uppercased()
}
```

Author — remove `.uppercased()` (line 81):
```swift
// Before: Text(author.uppercased())
Text(author)  // Natural case from feed
```

Domain — use lowercase (line 86):
```swift
// Before: Text(domain.uppercased())
Text(domain.lowercased())
```

Add favicon + metadata layout below title:
```swift
// Below title, replace separate author/domain VStack with:
HStack(alignment: .top, spacing: 8) {
    FaviconView(feed: entry.feed)
        .frame(width: 20, height: 20)
    VStack(alignment: .leading, spacing: 2) {
        if let domain = entry.displayDomain, !domain.isEmpty {
            Text(domain.lowercased())
                .font(.system(size: FontTheme.captionSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        if let author = entry.author, !author.isEmpty {
            Text(author)
                .font(.system(size: FontTheme.captionSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
```

**CSS changes** (article-style.css):
```css
/* Before: text-transform: uppercase */
.author { text-transform: none; }
.domain { text-transform: lowercase; }
```

**ArticleWebView** (line 42) — remove `.uppercased()` on domain in HTML template.

**Acceptance**: No ALL CAPS anywhere in the app. Date in Title Case ("Monday 2. April 2026 at 14.30"). Author in natural case. Domain in lowercase.

**Commit checkpoint**: `style(detail): fix metadata casing, add favicon to article header`

#### Step 2.3: Native selection styling

**Files**:
- `Feeder/Views/ContentView.swift` — remove custom `listRowBackground`
- `Feeder/Views/FontTheme.swift` — remove `listSelectionColor` (dead code after change)

**Change** (ContentView.swift lines 113-121):
Remove the entire `.listRowBackground(...)` modifier from the `ForEach` in `EntryListView`.

```swift
// Before:
.listRowBackground(
    RoundedRectangle(cornerRadius: 8)
        .fill(selectedEntry == entry
            ? FontTheme.listSelectionColor
            : Color.clear)
        .padding(.horizontal, 4)
)

// After: (removed entirely — native macOS selection)
```

Also remove `.scrollContentBackground(.hidden)` (line 132) to let native list background show.

**Acceptance**: Selection uses native macOS highlight (blue when focused, gray when unfocused). No custom background override. Row separators may need adjustment — test and tweak.

**Commit checkpoint**: `style(list): use native macOS selection styling`

#### Step 2.4: Subtle animations

**Files**:
- `Feeder/Views/ContentView.swift` — add transition animations
- `Feeder/Views/EntryDetailView.swift` — add panel transition

**Animations to add**:

1. **Article list content transition** — when filter or category changes:
```swift
EntryListView(...)
    .animation(.easeInOut(duration: 0.2), value: articleFilter)
    .animation(.easeInOut(duration: 0.2), value: selectedCategory)
```

2. **Detail panel crossfade** — when switching reader/web mode:
```swift
Group {
    switch viewMode {
    case .web: ArticleWebView(entry: entry)
    case .reader: readerView
    }
}
.animation(.easeInOut(duration: 0.25), value: viewMode)
```

3. **Status text transitions**:
```swift
Text(fetchStatus)
    .contentTransition(.numericText())
```

All animations must respect `accessibilityReduceMotion`:
```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// Use: .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: ...)
```

**Acceptance**: Transitions feel smooth and fast. No animations when Reduce Motion is enabled. No animation interferes with scroll performance.

**Commit checkpoint**: `style(views): add subtle transition animations`

#### Step 2.5: Color palette refinement

**Files**:
- `Feeder/Views/FontTheme.swift` — update color constants
- `Feeder/Resources/article-style.css` — update dark mode CSS variables

**FontTheme updates** (based on Feedbin reference analysis):

| Property | Before | After | Rationale |
|----------|--------|-------|-----------|
| `domainPillColor` | `#E8654A` (bright orange) | `Color(nsColor: .secondaryLabelColor)` (~`#8A8A8A`) | Feed name is metadata, not headline |
| `listSelectionColor` | `.unemphasizedSelectedContentBackgroundColor` | Removed (native selection) | Native handles focus states |

**CSS dark mode updates**:
```css
@media (prefers-color-scheme: dark) {
    :root {
        --accent: #C0463A;    /* muted red (was #E8654A) */
        --link: #4A90D9;      /* standard blue for links */
        --bg: #1E1E1E;        /* explicit dark gray */
    }
}
```

**Acceptance**: Dark mode feels like a native macOS app. Accent color is present but not dominant. Feed names and timestamps are subdued.

**Commit checkpoint**: `style(theme): refine dark mode color palette`

---

### M3: Final Verification & Cleanup

#### Step 3.1: Run full test suite

```bash
make test-all
```

**Acceptance**: All tests green. Zero warnings, zero errors.

#### Step 3.2: Post-fix performance measurement

Re-run all M0 measurements:
- `_printChanges()` body evaluation count during full sync → compare to baseline
- `testScrollPerformance()` duration → compare to baseline
- Thread assertions → all pass (DataWriter never on main thread)

Record results in execution log.

**Acceptance**: Measurable improvement over baseline. Target: ≥50% reduction in unnecessary body evaluations.

#### Step 3.3: Remove debug instrumentation

Remove `_printChanges()` calls and body counters added in M0 (keep thread assertions for ongoing safety).

#### Step 3.4: Visual review

Manual dark mode review checklist:
- [ ] Feed names: natural case, muted gray
- [ ] Section headers: Title Case, not ALL CAPS
- [ ] Article title: primary color, bold
- [ ] Detail panel: date Title Case, author natural case, domain lowercase
- [ ] Detail panel: favicon + metadata layout correct
- [ ] Selection: native macOS blue (focused) / gray (unfocused)
- [ ] Transitions: smooth, fast, no jank
- [ ] Reduce Motion: all animations disabled

**Commit checkpoint**: `chore(cleanup): remove debug instrumentation, final polish`

---

## 3. Risks

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|------------|------------|
| 1 | **DataWriter runs on main thread** (thread affinity bug) | CRITICAL — all perf work wasted if true | Medium | M0 Step 0.1 verifies first. If true: fix init pattern before M1 |
| 2 | **Removing listRowBackground exposes visual issues** | Medium — row separators, spacing may look wrong | Medium | Test thoroughly. Can add minimal background back if needed |
| 3 | **Schema version bump triggers full re-sync** | Low — expected behavior, documented | Certain | Users know to expect this. Only one bump needed (12→13) |
| 4 | **syncIcons becoming async changes SyncEngine call pattern** | Low — straightforward refactor | Low | Test sync flow end-to-end after change |
| 5 | **Animations cause new jank** | Medium — defeats the purpose | Low | Keep durations short (≤250ms). Test with Instruments |

### Critical gate: M0 Step 0.1

If DataWriter thread assertions fire (DataWriter is on main thread), **stop M1 and fix thread affinity first**. This would mean:
- Change `SyncEngine.configure()` to create DataWriter via `Task.detached { DataWriter(modelContainer:) }`
- Or create DataWriter in `FeederApp` init and inject it

This is the single biggest risk. If confirmed, it explains the jank far more than any other hotspot.

---

## 4. Confidence

| Milestone | Confidence | Notes |
|-----------|------------|-------|
| M0: Baseline measurement | **High** | Standard instrumentation, low risk |
| M1: Performance fixes | **High** | Root causes well-understood, fixes are targeted |
| M2: Visual polish | **Medium-High** | Design direction clear (Feedbin reference), but native selection needs hands-on testing |
| M3: Verification | **High** | Mechanical — run tests, compare numbers |

---

## 5. Quality Gates

### Before PR creation
- [ ] `make test-all` passes (zero warnings, zero errors)
- [ ] No `AsyncImage` in codebase
- [ ] No `.uppercased()` in view rendering (except single-letter favicon fallback)
- [ ] No `stripHTMLToPlainText` called during rendering
- [ ] Thread assertions pass (DataWriter off main thread)
- [ ] `_printChanges()` debug instrumentation removed
- [ ] All animations respect `accessibilityReduceMotion`

### PR review checklist
- [ ] Performance improvement demonstrated with before/after numbers
- [ ] Dark mode visual review passed
- [ ] Schema version bumped correctly
- [ ] No dead code (old `listSelectionColor`, unused `progress` string, etc.)
- [ ] CSS dark mode updated to match SwiftUI changes

---

## 6. File Change Summary

| File | Changes |
|------|---------|
| `Feeder/Models/Entry.swift` | Add `summaryPlainText: String = ""` |
| `Feeder/Models/Feed.swift` | Add `faviconData: Data?` |
| `Feeder/FeederApp.swift` | Bump `currentSchemaVersion` 12→13 |
| `Feeder/DataWriter.swift` | Compute `summaryPlainText` at persist time; download favicon data in `syncIcons`; thread assertions |
| `Feeder/Views/EntryRowView.swift` | Use pre-computed summary; replace `AsyncImage` with `Image(nsImage:)`; remove `.uppercased()` on feed name |
| `Feeder/Views/ContentView.swift` | Extract `SyncStatusView`; remove custom `listRowBackground`; remove `.scrollContentBackground(.hidden)`; section labels Title Case; add animations |
| `Feeder/Views/EntryDetailView.swift` | Remove ALL CAPS from date/author/domain; add favicon layout; add panel transition |
| `Feeder/Views/ArticleWebView.swift` | Remove `.uppercased()` on domain |
| `Feeder/Views/FontTheme.swift` | Change `domainPillColor` to `.secondaryLabelColor`; remove `listSelectionColor` |
| `Feeder/Resources/article-style.css` | Update dark mode accent/link colors; remove `text-transform: uppercase` |
| `Feeder/FeedbinAPI/SyncEngine.swift` | Throttle `fetchedCount` updates |
| `Feeder/Classification/ClassificationEngine.swift` | Throttle `classifiedCount` updates |
| `FeederUITests/FeederUITests.swift` | Add scroll performance test |

---

## 7. Execution Order

```
M0.1 → M0.2 → M0.3 → [baseline recorded]
  ↓
M1.1 (summary precompute) → M1.2 (favicon cache) → M1.3 (throttle) → M1.4 (isolate status) → M1.5 (measure)
  ↓
M2.1 (colors + feed names) → M2.2 (detail metadata) → M2.3 (selection) → M2.4 (animations) → M2.5 (CSS)
  ↓
M3.1 (tests) → M3.2 (measure) → M3.3 (cleanup) → M3.4 (visual review)
```

M1 steps are sequential — each fix should be measured individually to understand its contribution. M2 steps can be partially parallelized but are ordered for logical coherence.

Total estimated commits: ~10 (one per step + merge).
