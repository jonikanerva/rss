# Research: UI Performance & Visual Polish

Date: 2026-04-02
Status: Complete (updated with deep-dive findings)
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

#### Hotspot 0: AsyncImage for Favicons — No Caching, Network During Scroll (CRITICAL)

**Location**: `EntryRowView.swift:89` → `FaviconView.body`

Every article row uses `AsyncImage(url:)` to load its feed's favicon:

```swift
AsyncImage(url: url) { phase in
  switch phase {
  case .success(let image):
    image.resizable().aspectRatio(contentMode: .fit).clipShape(...)
  default:
    initialsIcon
  }
}
```

**Why this is the most likely primary cause of scroll jank:**

1. **No cross-lifecycle caching**: `AsyncImage` relies on `URLSession`'s default `URLCache`. When List recycles cells during scroll, each new `AsyncImage` instance re-evaluates — triggering a cache lookup + potential network request. Even cached responses require main-thread work (cache read, data → Image decode).

2. **Image decoding on main thread**: When `AsyncImage` transitions from `.empty` to `.success`, the decoded bitmap is created synchronously on the main thread. With 15-20 visible rows, this is 15-20 decode operations per scroll page.

3. **Duplicate requests for same feed**: If 10 articles belong to "The Verge", there are 10 independent `AsyncImage` instances for the same favicon URL. No deduplication.

4. **Phase transitions cause re-renders**: Each `AsyncImage` goes through `.empty` → `.success` (or `.failure`), causing each row to render twice. During scroll, this doubles the row rendering workload.

5. **Not throttled or prioritized**: `AsyncImage` uses default `URLSession` priority. During sync, favicon fetches compete with Feedbin API requests for network bandwidth and connection slots.

**Evidence**: This pattern is a well-known SwiftUI performance anti-pattern for scrollable lists. Apple's WWDC sessions recommend pre-caching images or using dedicated image loading libraries with memory/disk caches for list rows.

#### Hotspot 0b: stripHTMLToPlainText Called in View Body (HIGH)

**Location**: `EntryRowView.swift:26-29`

```swift
private var summaryText: String {
  if let summary = entry.summary, !summary.isEmpty {
    return stripHTMLToPlainText(summary)
  }
  return entry.plainText
}
```

This computed property runs **every time** the row's body is evaluated. `stripHTMLToPlainText` performs **two regex replacements** on potentially large HTML strings:
- `<[^>]+>` — strip all HTML tags
- `\\s+` — normalize whitespace

Regex execution on HTML is CPU-intensive. While `entry.plainText` is pre-computed at persist time (good), this code path **bypasses the pre-computed value** when `entry.summary` is non-nil and non-empty — which is common for many RSS feeds.

**Impact**: During sync, when @Observable updates cause `ContentView` body re-evaluation, every visible row re-runs this regex. With 20 visible rows × 2 regex passes × frequent re-evaluations = significant CPU burn on MainActor.

**Fix**: Pre-compute the summary plain text at persist time in `DataWriter`, just like `plainText` is already pre-computed for classification.

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

#### Hotspot 4: groupedByDay() Recomputation (LOW-MEDIUM)

`let sections = groupedByDay(entries)` runs on every body evaluation (`ContentView.swift:105`). This creates new `DaySection` arrays from the full entry list. For each entry, it calls `Calendar.startOfDay(for:)` and for each new day group, runs date formatting with `sectionLabel(for:)`. With 500+ entries, this is non-trivial CPU work on MainActor during every re-render.

Additionally, `sectionLabel()` (`ContentView.swift:42-54`) uses `date.formatted()` calls and `.uppercased()` — which creates new strings every time. This function is called once per unique day in the data, so ~7 times for a week's worth of articles.

#### Hotspot 5: pendingReadIDs Environment Propagation (LOW-MEDIUM)

**Location**: `ContentView.swift:218`

```swift
.environment(\.pendingReadIDs, pendingReadIDs)
```

When a user selects an article, `pendingReadIDs` is modified → the environment value changes → **every row** in `EntryListView` receives the new environment and re-evaluates its body. Each row checks `pendingReadIDs.contains(entry.feedbinEntryID)` to determine visual read state. With 200+ rows, this means all visible rows re-render on every article selection — even though only one row's visual state changed.

#### Hotspot 6: DataWriter Init on MainActor (NEEDS VERIFICATION)

**Location**: `SyncEngine.swift:46`

```swift
func configure(..., modelContainer: ModelContainer) {
  self.writer = DataWriter(modelContainer: modelContainer)
```

`SyncEngine` is `@MainActor`, so `configure()` runs on MainActor. The earlier research (2026-03-15-background-context-architecture.md:190) flagged: "@ModelActor queue inheritance — if init runs on MainActor, actor executes on main queue."

If this is true, **all DataWriter operations (HTML parsing, SwiftData writes) would run on the main thread**, completely defeating the two-layer architecture. However, modern `@ModelActor` may create its own background serial queue regardless of init context — this needs verification with Instruments or thread logging.

#### Hotspot 7: applyClassification Re-fetches Categories Every Call (LOW)

**Location**: `DataWriter.swift:361`

```swift
func applyClassification(entryID: Int, result: ClassificationResult) throws {
  ...
  let categories = try fetchCategoryDefinitions()
```

Called once per article during classification. Each call fetches all categories from SwiftData + creates DTOs + builds a dictionary. With 1000 articles, that's 1000 redundant category fetches. Categories don't change during classification — this should be fetched once and passed in.

#### Hotspot 8: updateReadState Fetches ALL Entries (LOW)

**Location**: `DataWriter.swift:263-264`

```swift
func updateReadState(unreadIDs: Set<Int>) throws {
  let descriptor = FetchDescriptor<Entry>()
  let allEntries = try modelContext.fetch(descriptor)
```

Fetches every entry from the database with no predicate, then iterates all to compare read state. With 1000+ entries, this is wasteful — could use a predicate to fetch only entries whose read state needs changing.

### What It's NOT

- ❌ Not ModelContext contention on MainActor (DataWriter is properly isolated — if init is correct)
- ❌ Not heavy article detail rendering (only runs for selected article, not during scroll)
- ❌ Not @Query predicate issues (predicates push to SQLite correctly)

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

### D. Replace AsyncImage with Cached Favicon Loading

**Approach**: Replace `AsyncImage` in `FaviconView` with a pre-cached image system. Options:
1. **Pre-download favicons in DataWriter** at sync time (when `syncIcons` runs) and store as `Data` on the `Feed` model. Render with `Image(nsImage: NSImage(data:))` — zero network during scroll.
2. **In-memory cache with `NSCache`**: Download favicon once per unique URL, cache the `NSImage` in memory. Use `@State` + `task` pattern for async load with cancellation.
3. **URLSession with aggressive caching**: Configure a dedicated `URLSession` with large `URLCache` and `returnCacheDataElseLoad` policy.

```
Pros: Eliminates all network I/O during scroll. Eliminates duplicate fetches.
      Option 1 is simplest and most reliable (zero network, works offline).
Cons: Option 1 increases database size slightly (~1-5KB per feed × ~50 feeds = negligible).
Risk: Low.
```

### E. Pre-compute Summary Plain Text

**Approach**: Add a `summaryPlainText` field to `Entry` and compute it in `DataWriter.persistEntries()`, just like `plainText` is already computed. Remove the runtime `stripHTMLToPlainText` call from `EntryRowView.summaryText`.

```
Pros: Eliminates regex execution during scroll. Trivial change.
Cons: Slightly larger database per entry (one more text field).
Risk: Very low.
```

### F. Combined Approach (Recommended)

Apply D + E + A + B together, in priority order:
1. **Replace AsyncImage with cached favicons** (biggest impact — eliminates network + decode during scroll)
2. **Pre-compute summary plain text** (eliminates regex during scroll)
3. **Throttle progress counter updates** to ~200ms intervals (reduces view invalidations)
4. **Isolate status display** so progress changes don't invalidate the list panel
5. Optionally batch classification saves (lower priority, test if 1-4 are sufficient)

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

1. **DataWriter thread affinity**: Does `@ModelActor` init'd from MainActor actually execute on the main queue? If yes, this is the single biggest performance bug — all HTML parsing, SwiftData writes, and classification I/O would block the UI thread. Must verify with `Thread.isMainThread` logging or Instruments.

2. **AsyncImage caching behavior**: How does `AsyncImage` behave with Feedbin's favicon CDN? Do favicon URLs have cache-busting query params? If the CDN returns proper `Cache-Control` headers, `URLCache` hits may be fast enough — but image decode still happens on main thread.

3. **Exact contribution of each hotspot**: Without Instruments profiling, the relative impact of each hotspot is estimated. AsyncImage + stripHTML are the most likely primary causes based on code analysis, but @Observable propagation may dominate in practice.

4. **List selection behavior after removing custom background**: Removing `listRowBackground` may expose other styling issues (row separators, spacing). Needs hands-on testing.

5. **Accent color perception**: The "pure black background" complaint may partly be a contrast illusion from the bright #E8654A accent. Need to test with a more muted accent before changing backgrounds.

### Biggest Risk

**DataWriter thread affinity** (Hotspot 6). If DataWriter is running on the main thread, every `parseHTMLToBlocks()` call (XML parsing + tree walking per article), every `modelContext.save()`, and every `stripHTMLToPlainText()` regex runs on MainActor. This would explain the jank far more than @Observable updates alone. This must be verified first — if confirmed, fixing it may resolve the jank without needing the other performance changes.

---

## 8. Recommendation

**Evidence is sufficient to plan.** The root causes are well-understood, the fixes are scoped, and there are clear before/after verification methods (Instruments profiling, visual inspection).

### Prioritized hotspot severity (updated)

| # | Hotspot | Severity | Confidence |
|---|---------|----------|------------|
| 0 | AsyncImage favicons — network + decode during scroll | CRITICAL | High |
| 0b | stripHTMLToPlainText regex in view body | HIGH | High |
| 1 | @Observable high-frequency updates | HIGH | High |
| 2 | @Environment propagation scope | MEDIUM | High |
| 6 | DataWriter init on MainActor (thread affinity) | CRITICAL if true | Needs verification |
| 3 | @Query re-evaluation per classification save | MEDIUM | Medium |
| 4 | groupedByDay() recomputation | LOW-MEDIUM | High |
| 5 | pendingReadIDs environment propagation | LOW-MEDIUM | High |
| 7 | applyClassification re-fetches categories | LOW | High |
| 8 | updateReadState fetches all entries | LOW | High |

### Suggested plan scope (for `/plan` phase):

**Performance (priority order):**
1. Verify DataWriter thread affinity — if on main thread, fix init to use background
2. Replace AsyncImage with pre-cached/in-memory favicon system
3. Pre-compute summary plain text at persist time (eliminate runtime regex)
4. Throttle @Observable progress updates + isolate status view from list panel
5. Batch classification saves (if still needed after 1-4)

**Visual polish:**
6. Dark theme: audit backgrounds, consider muting accent color
7. Selection: remove custom `listRowBackground`, test native selection
8. Animations: add 3-4 subtle transitions (selection, article appearance, panel switch)
9. Metadata: fix ALL CAPS → Title Case / lowercase in both panels + CSS
10. Verification: Instruments profiling before/after, visual review in dark mode
