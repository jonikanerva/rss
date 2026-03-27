# Research: Read/Unread Tabs in Article List Panel

Date: 2026-03-27
Status: Complete

## Problem

The second panel (article list) currently shows all articles for a category regardless of read status. Users want to quickly toggle between viewing unread articles (the primary working set) and read articles (for reference/re-reading). This is a standard feature in RSS readers — most users spend 90%+ of their time in the "unread" view.

## Constraints

1. **SwiftData `@Query` limitations**: Predicates must be fully expressible in `#Predicate<Entry>` macro syntax. The predicate is set at `init()` time — it cannot be changed dynamically after view creation.
2. **Swift 6 strict concurrency**: All UI state on MainActor. No `@Query` result filtering in-memory (project rule: push predicates to SQLite).
3. **Three-pane NavigationSplitView**: The tab control must fit naturally in the content pane (panel 2) without disrupting the existing navigation title area.
4. **Existing `isRead` field**: `Entry.isRead` is already a persisted SwiftData boolean, updated during sync and on article selection. No schema changes needed.
5. **Selection state**: `selectedEntry` must be preserved or gracefully cleared when switching tabs (an entry visible in "unread" disappears from that list once read).

## Alternatives

### Option A: Picker in toolbar (segmented control)

Add a `@State private var articleFilter: ArticleFilter` enum (`.unread`, `.read`) to `ContentView`. Pass it to `EntryListView` which incorporates it into the `#Predicate`.

**Implementation:**
- Add `Picker` with `.segmentedControl` style in the content area's toolbar or as a `.safeAreaInset(edge: .top)`.
- `EntryListView.init(category:filter:selectedEntry:)` builds predicate with `isRead` condition.
- SwiftData handles the predicate at SQLite level — no in-memory filtering.

**Pros:**
- Native macOS pattern (Mail.app uses similar segmented filters).
- Minimal code change — only `EntryListView.init` and one `@State` in `ContentView`.
- Predicate stays in SQLite — zero performance concern.
- Familiar UX, immediately discoverable.

**Cons:**
- Segmented control takes vertical space.
- Two-option picker might feel heavy for a binary toggle.

### Option B: Toggle button in toolbar

A single toolbar button (e.g., eye icon) that toggles between showing all/unread articles.

**Pros:**
- Compact, minimal space.
- Common in feed readers (NetNewsWire uses this pattern).

**Cons:**
- Less discoverable than tabs/segments — state not visually obvious.
- "All" vs "Unread" is different from "Read" vs "Unread" — user requested the latter.
- Three states (all/unread/read) would need a menu, not a toggle.

### Option C: Inline tab bar (custom)

Custom `HStack` with two text buttons ("Unread" / "Read") styled as tab-like buttons at the top of the list, inside `.safeAreaInset(edge: .top)`.

**Pros:**
- Full visual control, matches app's "clear and calm" aesthetic.
- Can show unread counts in the tab labels.
- Sits within the content pane, not in the macOS toolbar.

**Cons:**
- More custom code than native Picker.
- Must handle accessibility, keyboard navigation manually.
- Risk of looking non-native on macOS.

## Evidence

### Prior art in RSS readers

- **NetNewsWire**: Sidebar filter (All/Unread toggle). Not per-category.
- **Reeder**: Tab bar at top of article list with Unread/All/Starred segments.
- **Apple Mail**: Segmented "All/Unread" in toolbar, per-mailbox.
- **Feedbin web**: "Show read" toggle per feed/category.

### SwiftData predicate composition

SwiftData `#Predicate` supports combining conditions with `&&`:

```swift
// Unread only
#Predicate<Entry> { $0.isClassified && $0.primaryCategory == category && !$0.isRead }

// Read only
#Predicate<Entry> { $0.isClassified && $0.primaryCategory == category && $0.isRead }
```

This works because `isRead` is a simple stored Bool — no optionals, no relationships to traverse. The predicate compiles to a SQLite WHERE clause.

### SwiftData @Query recreation

Since `@Query` predicates are set in `init()`, changing the filter requires **recreating** the `EntryListView`. SwiftUI handles this automatically when the `id` or init parameters change — passing a different `filter` value will cause SwiftUI to create a new `EntryListView` instance with the updated predicate. This is the standard pattern for dynamic `@Query` filtering.

### Empty state UX

When switching to "Read" tab with no read articles (or "Unread" with none), the existing `ContentUnavailableView` overlay handles this gracefully. The message text should be tab-aware:
- Unread: "No unread articles in this category."
- Read: "No read articles in this category."

## Unknowns

1. **Selection behavior on tab switch**: If user is reading an article (which gets marked read), it disappears from the "Unread" list. Should `selectedEntry` be cleared on tab switch, or should we try to preserve it? **Recommendation**: Clear selection on tab switch — simpler and avoids stale state.

2. **Default tab**: Should the default be "Unread"? Almost certainly yes — unread is the primary workflow.

3. **Unread count in tab label**: Should the "Unread" tab show a count? Nice to have but adds complexity (needs a separate `@Query` for count). **Recommendation**: Defer to polish phase.

**Biggest risk**: SwiftData predicate recreation performance when switching tabs rapidly. Low risk — SQLite is fast and the dataset is small (hundreds to low thousands of entries per category).

## Recommendation

**Evidence is sufficient to plan.** Recommend **Option A (Picker with segmented control)** for these reasons:

1. Native macOS pattern — consistent with platform conventions.
2. Minimal code change — one enum, one `@State`, modified `EntryListView.init`, one `Picker`.
3. All filtering in SQLite via `#Predicate` — follows project rules.
4. No schema changes — `isRead` already exists.
5. Clear, discoverable UX — both states always visible.

The Picker can be placed as a `.safeAreaInset(edge: .top)` or in the content toolbar. Recommend `.safeAreaInset` for tighter integration with the list.

Proceed to `/plan` phase.
