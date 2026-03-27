# Plan: Read/Unread Tabs in Article List Panel

Date: 2026-03-27
Research: `docs/research/2026-03-27-article-list-read-unread-tabs.md`
Status: Draft

## Scope

Add a segmented Picker ("Unread" / "Read") to the top of the article list panel (panel 2). Selecting a segment filters the `@Query` predicate so only unread or read articles are shown. Default to "Unread". All filtering happens at the SQLite level via SwiftData predicates — no in-memory filtering.

**Files touched:** `ContentView.swift` only. No new files, no model changes, no schema changes.

## Milestones

### M1: ArticleFilter enum

Add an `ArticleFilter` enum to `ContentView.swift` (above `EntryListView`).

```swift
enum ArticleFilter: String, CaseIterable {
  case unread = "Unread"
  case read = "Read"
}
```

**Acceptance:** Compiles. No UI changes yet.
**Confidence:** High.

### M2: Update EntryListView to accept filter parameter

Modify `EntryListView.init` to accept `filter: ArticleFilter` and incorporate `isRead` into the `#Predicate`:

```swift
init(category: String, filter: ArticleFilter, selectedEntry: Binding<Entry?>) {
  let showRead = filter == .read
  _entries = Query(
    filter: #Predicate<Entry> {
      $0.isClassified && $0.primaryCategory == category && $0.isRead == showRead
    },
    sort: \Entry.publishedAt,
    order: .reverse
  )
  _selectedEntry = selectedEntry
}
```

Update the empty state text to be filter-aware:
- Unread: "No unread articles in this category."
- Read: "No read articles in this category."

**Acceptance:** Compiles. EntryListView now requires `filter` parameter.
**Confidence:** High — `isRead` is a simple stored Bool, predicate composition with `==` is well-supported.

### M3: Add filter state and Picker to ContentView

1. Add `@State private var articleFilter: ArticleFilter = .unread` to `ContentView`.
2. Add a `Picker` with `.segmented` style inside `.safeAreaInset(edge: .top)` on the `EntryListView`, or in the content toolbar.
3. Pass `articleFilter` to `EntryListView`.
4. Clear `selectedEntry` when `articleFilter` changes (via `.onChange`).

```swift
// In the content section of NavigationSplitView:
EntryListView(category: category, filter: articleFilter, selectedEntry: $selectedEntry)
  .safeAreaInset(edge: .top) {
    Picker("Filter", selection: $articleFilter) {
      ForEach(ArticleFilter.allCases, id: \.self) { filter in
        Text(filter.rawValue).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
  .navigationTitle(navigationTitle)
```

5. Add `.onChange(of: articleFilter)` to clear selection:

```swift
.onChange(of: articleFilter) {
  selectedEntry = nil
}
```

**Acceptance:** Segmented picker visible at top of article list. Switching between Unread/Read filters the list. Selection clears on tab switch. Default is Unread.
**Confidence:** High.

### M4: Update Preview

Update `timelineSeededDemoPreview()` to set some entries as read so both tabs show data in the preview.

**Acceptance:** Preview renders both tabs with entries.
**Confidence:** High.

### M5: Build verification & test

Run `bash .claude/scripts/test-all.sh`. Zero warnings, zero errors.

**Acceptance:** All green.
**Confidence:** High.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `#Predicate` doesn't support `== showRead` with captured local | Low | Blocks M2 | Use two separate predicates in a switch statement instead |
| Article disappears from "Unread" while being read, feels jarring | Medium | UX annoyance | Acceptable — user can find it in "Read" tab. This is standard RSS reader behavior |
| Rapid tab switching causes query churn | Low | Performance | SwiftData cancels previous query; SQLite is fast on indexed Bools |

## Quality gates

1. `bash .claude/scripts/test-all.sh` — all green (zero warnings, zero errors).
2. Manual verification: switching tabs filters correctly, empty states show correct text, selection clears on tab switch.
3. Default tab is "Unread" on app launch.
4. Accessibility: Picker has accessible label, VoiceOver announces filter state.
