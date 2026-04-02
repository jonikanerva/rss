# Research: UI Performance & Visual Polish

Date: 2026-04-02
Status: Complete
Scope: Scroll jank during sync + dark theme / selection / animation / metadata polish

---

## 1. Problem

Two interrelated issues degrade the dogfooding experience:

### A. Scroll Jank During Sync

The article list (2nd panel, `EntryListView`) stutters when `SyncEngine` or `ClassificationEngine` are active. Users notice this every time a sync runs — which is every app launch and every periodic refresh.

### B. Visual Polish Gaps

- **Dark theme**: Pure-black–feeling background; the red-orange accent (#E8654A) is too saturated for highlights.
- **Selection styling**: Custom `listRowBackground` with `RoundedRectangle` overrides native macOS selection, producing inconsistent blue/gray appearance depending on window focus.
- **Animations**: Zero animations anywhere — state changes are instantaneous, making the app feel flat.
- **3rd panel metadata**: Author is `.uppercased()`, domain is `.uppercased()`, date uses ALL CAPS weekday — violates the "No ALL CAPS anywhere" requirement.
- **2nd panel site name**: `feedName.uppercased()` — should be Title Case.

---

## 2. Constraints

- **Swift 6 strict concurrency**: No GCD, no locks, no Combine. `Task.sleep(for:)` only.
- **Two-layer architecture**: All writes via `DataWriter` (@ModelActor, background). `SyncEngine`/`ClassificationEngine` are `@Observable` on `@MainActor` for progress display only.
- **App rules (locked)**: Status text format is locked — "Fetching xxx/yyy" and "Categorizing xxx/yyy" only. No provider names, no phase details.
- **@Query predicates**: Must stay in SQLite — no Swift-side filtering.
- **Pre-computed display fields**: Already done at persist time in `DataWriter` (good).
- **Existing List implementation**: Uses `List(selection:)` with `ForEach` sections, `.inset(alternatesRowBackgrounds: false)`, custom `listRowBackground`.

---

## 3. Root Cause Analysis — Scroll Jank

### Architecture Review

The data flow is well-designed: `DataWriter` handles all SwiftData writes on a background actor, and `SyncEngine`/`ClassificationEngine` only hold UI counters on `@MainActor`. There is **no ModelContext contention** — the architecture is clean.

### Identified Hotspots

#### Hotspot 1: High-Frequency @Observable Updates (HIGH)

**SyncEngine** updates `fetchedCount` on every batch (every 100 entries) and every page during incremental sync:
- `SyncEngine.swift:155` — `fetchedCount = batchEnd` in unread sync loop
- `SyncEngine.swift:189` — `fetchedCount = allEntries.count` in page stream loop

**ClassificationEngine** updates `classifiedCount` on every single article:
- `ClassificationEngine.swift:200` — `classifiedCount += 1` per article
- `ClassificationEngine.swift:201` — `progress` string rebuilt per article

SwiftUI's `@Observable` does coalesce synchronous changes within a single RunLoop cycle. However, these updates happen across `await` boundaries (network fetches, actor hops), so **each update is a separate transaction** that triggers a separate view invalidation.

**Impact chain:**
1. `fetchedCount` changes → `ContentView.fetchStatusText` (computed property) re-evaluates
2. `ContentView` body re-evaluates (it reads both engines via `@Environment`)
3. The entire `NavigationSplitView` body re-runs, including `EntryListView`
4. `List` diffs its children — this is fast but not free, especially with 100+ rows

#### Hotspot 2: @Environment Propagation Scope (MEDIUM)

Both engines are injected via `.environment()` at the app root. When any `@Observable` property changes, **every view that reads the environment object** is invalidated. `ContentView` reads both engines, and its body contains the entire three-panel layout.

The sidebar status text is the only consumer of progress counters, but the invalidation propagates to the entire `ContentView` body because observation tracking happens at the view body level.

#### Hotspot 3: @Query Re-evaluation on Background Saves (MEDIUM)

When `DataWriter.applyClassification()` calls `modelContext.save()`, SwiftData's `automaticallyMergesChangesFromParent` propagates the change to the main context. This triggers `@Query` re-evaluation for `EntryListView`. During classification of 1000 articles, this means up to 1000 `@Query` re-evaluations — each fetching the full result set from SQLite.

However, `List` uses cell recycling and diffs efficiently, so individual saves during classification may not cause visible jank unless they coincide with scroll gestures.

#### Hotspot 4: groupedByDay() Recomputation (LOW)

`let sections = groupedByDay(entries)` runs on every body evaluation. This creates new `DaySection` arrays from the full entry list. With 500+ entries, this is non-trivial CPU work during scroll.

### What It's NOT

- ❌ Not ModelContext contention (DataWriter is properly isolated)
- ❌ Not expensive render-time computation (display fields are pre-computed)
- ❌ Not @Query predicate issues (predicates push to SQLite correctly)
- ❌ Not heavy row views (EntryRowView is lightweight)

---

## 4. Alternatives

### A. Throttle @Observable Progress Updates

**Approach**: Update `fetchedCount`/`classifiedCount` at most once per ~200ms using a time-based gate.

```
Pros: Simple, targeted fix. Reduces view invalidations from 1000+ to ~50.
Cons: Progress counter appears less smooth (jumps). Acceptable for "Fetching 450/1200".
Risk: Low — purely cosmetic change to update frequency.
```

### B. Isolate Progress Display into Dedicated View

**Approach**: Extract sidebar status into a standalone `SyncStatusView` that directly reads the engine properties. Remove engine `@Environment` reads from `ContentView` body.

```
Pros: Observation scope is narrowed — only the status text re-renders on counter changes.
      EntryListView is completely unaffected by progress updates.
Cons: Requires restructuring view hierarchy. Must ensure environment still propagates to children.
Risk: Medium — SwiftUI environment propagation can be tricky with NavigationSplitView.
```

### C. Batch DataWriter Saves During Classification

**Approach**: Instead of `modelContext.save()` after each `applyClassification()`, accumulate N results and save in batch.

```
Pros: Reduces @Query re-evaluations from 1000 to ~20 (batch of 50).
Cons: Articles appear in the list in chunks rather than one-by-one.
      More complex error handling if a batch partially fails.
Risk: Medium — changes DataWriter's save semantics.
```

### D. Combined Approach (Recommended)

Apply A + B together:
1. Throttle progress counter updates to ~200ms intervals
2. Isolate status display so progress changes don't invalidate the list panel
3. Optionally batch classification saves (lower priority, test if A+B are sufficient)

---

## 5. Visual Polish — Analysis & Options

### 5.1 Dark Theme Background

**Current state**: App uses `.scrollContentBackground(.hidden)` and no explicit window background, inheriting system defaults. The CSS dark mode uses `--bg: #1d1d1f` which is Apple's standard dark gray.

**SwiftUI side**: The "pure black" feel likely comes from `List` with `.scrollContentBackground(.hidden)` over no explicit background, defaulting to the window's `controlBackgroundColor` (~#1E1E1E).

**Recommendation**: Use macOS semantic colors explicitly:
- Window/sidebar: `.background(.regularMaterial)` for vibrancy, or `Color(.windowBackgroundColor)` (#323232 in dark)
- Content area: `Color(.controlBackgroundColor)` (#1E1E1E) — this is correct and not "pure black"
- Reader pane: `Color(.textBackgroundColor)` (#1E1E1E)

**Investigate**: The perceived "pure black" may be a contrast illusion from the bright #E8654A accent. Toning down the accent may fix the perception without changing backgrounds.

### 5.2 Selection Styling

**Current state** (`ContentView.swift:113-121`):
```swift
.listRowBackground(
  RoundedRectangle(cornerRadius: 8)
    .fill(selectedEntry == entry
      ? FontTheme.listSelectionColor  // .unemphasizedSelectedContentBackgroundColor
      : Color.clear)
    .padding(.horizontal, 4)
)
```

**Problem**: `listRowBackground` draws **over** the native AppKit selection highlight. The app uses `unemphasizedSelectedContentBackgroundColor` which is the unfocused/gray selection — it never shows the blue focused selection that macOS users expect.

**Options**:

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| A. Remove custom bg | Drop `listRowBackground` entirely | Fully native selection | Lose rounded rect styling |
| B. Focus-aware bg | Read `@Environment(\.isFocused)` to switch between emphasized/unemphasized colors | Correct focus behavior | More complex, still overrides native |
| C. Overlay approach | Use `.listRowBackground(Color.clear)` + transparent overlay for hover only, let native selection show through | Best of both worlds | Needs testing on macOS 15 |

**Recommendation**: Option A (remove custom background) for correctness, then evaluate if additional styling is needed. Native macOS selection is well-understood by users.

### 5.3 Animations

**Current state**: Zero animations. All state changes are instantaneous.

**Recommended additions** (subtle, fast, premium):

| Element | Animation | Duration | Curve |
|---------|-----------|----------|-------|
| Article appearing (classification complete) | Opacity 0→1 + slight Y offset | 0.3s | `.spring(response: 0.4, dampingFraction: 0.75)` |
| Selection background change | Color transition | 0.2s | `.easeInOut(duration: 0.2)` |
| Panel transitions (reader/web toggle) | Crossfade | 0.25s | `.easeInOut` |
| Status text changes | Opacity transition | 0.15s | `.easeIn` |

**Must respect**: `accessibilityReduceMotion` — disable all non-essential animations.

### 5.4 Metadata Display (3rd Panel)

**Current state** (`EntryDetailView.swift:66-92`):
- Date: Orange, formatted as "EEEE d. MMMM yyyy AT HH.mm"
- Author: `.uppercased()` — ALL CAPS ❌
- Domain: `.uppercased()` — ALL CAPS ❌

**Required changes**:
- Author: Title Case (e.g., "John Gruber")
- Domain: lowercase (e.g., "daringfireball.net")
- Date: Title Case (e.g., "Monday 2. April 2026 at 14.30")
- Layout: favicon icon left, two rows right (domain lowercase, author Title Case)
- No ALL CAPS anywhere

**CSS (article-style.css)**: Lines 76-88 also apply `text-transform: uppercase` to `.author` and `.domain` — must be updated for web view mode too.

### 5.5 Site Name in 2nd Panel

**Current state** (`EntryRowView.swift:42`):
```swift
Text(feedName.uppercased())
```

**Required**: Title Case instead of `.uppercased()`. Use a `titleCased()` helper or `capitalized` property (note: Swift's `.capitalized` lowercases after first letter of each word — may need custom implementation for proper Title Case with acronyms).

---

## 6. Evidence

### Scroll Performance
- SwiftUI `@Observable` updates across `await` boundaries are **not coalesced** — each is a separate render transaction. Source: [Swift Forums](https://forums.swift.org/t/understanding-when-swiftui-re-renders-an-observable/77876), [Fat Bob Man](https://fatbobman.com/en/posts/mastering-observation/)
- `List` uses cell recycling (NSCollectionView underneath), so row rendering is O(visible) not O(total). Source: [Jacob's Tech Tavern](https://blog.jacobstechtavern.com/p/swiftui-scroll-performance-the-120fps)
- `@Query` re-evaluation on background save is confirmed behavior via `automaticallyMergesChangesFromParent`. Source: [Use Your Loaf](https://useyourloaf.com/blog/swiftdata-background-tasks/)

### macOS Dark Theme
- Apple uses #1E1E1E to #323232 for dark backgrounds, never #000000. Source: [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- Semantic colors adapt to vibrancy, accessibility, and desktop tinting. Source: [Indie Stack](https://indiestack.com/2018/10/supporting-dark-mode-adapting-colors/)

### Selection Styling
- `listRowBackground` draws over native AppKit selection highlight. Source: [Apple Forums](https://developer.apple.com/forums/thread/719507), [Eidinger Blog](https://blog.eidinger.info/til-swiftui-list-on-macos)

### Animations
- macOS desktop animations should be 200-350ms with easeInOut. Source: [Apple Developer Docs](https://developer.apple.com/documentation/swiftui/animations)
- Must check `accessibilityReduceMotion`. Source: [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/motion)

---

## 7. Unknowns

1. **Exact contribution of each hotspot**: We know the architecture has multiple sources of excess invalidation, but haven't profiled with Instruments to measure which contributes most to visible jank. The throttle + isolation fix should address all of them, but the relative impact is unknown.

2. **List selection behavior after removing custom background**: Removing `listRowBackground` may expose other styling issues (row separators, spacing). Needs hands-on testing.

3. **SwiftData @Query merge frequency**: How quickly do background `modelContext.save()` calls propagate to the main context? If there's built-in batching, classification saves may already be partially coalesced.

4. **Accent color perception**: The "pure black background" complaint may partly be a contrast illusion from the bright #E8654A accent. Need to test with a more muted accent before changing backgrounds.

### Biggest Risk

**View hierarchy restructuring for observation isolation** (Alternative B) — changing how `@Environment` objects propagate through `NavigationSplitView` can have non-obvious side effects. If done incorrectly, child views may lose access to engines, or the isolation may not actually prevent invalidation. Must verify with Instruments after the change.

---

## 8. Recommendation

**Evidence is sufficient to plan.** The root causes are well-understood, the fixes are scoped, and there are clear before/after verification methods (Instruments profiling, visual inspection).

### Suggested plan scope (for `/plan` phase):

1. **Performance**: Throttle observable updates + isolate status view from list panel
2. **Dark theme**: Audit backgrounds, consider muting accent color
3. **Selection**: Remove custom `listRowBackground`, test native selection
4. **Animations**: Add 3-4 subtle transitions (selection, article appearance, panel switch)
5. **Metadata**: Fix ALL CAPS → Title Case / lowercase in both panels + CSS
6. **Verification**: Instruments profiling before/after, visual review in dark mode
