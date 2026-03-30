# Implementation Plan: Domain Pill Badge & Open in Browser

Date: 2026-03-29
Research: `docs/research/2026-03-29-domain-pill-and-open-in-browser.md`

## 1. Scope

Add two UX improvements to the Feeder app:

1. **Domain pill badge** — a coral-colored (`#E8654A`) text label showing `domain.tld` (e.g., `theverge.com`) in both the article list (panel 2) and article detail (panel 3).
2. **Open in browser button** — a toolbar button in the detail panel with safari icon, calling the existing `openInBackground()` logic. Tooltip shows keyboard shortcut `B`.

### Why

- Users cannot quickly identify article sources without reading the full feed title.
- The existing `B` keyboard shortcut to open articles in browser is undiscoverable.

## 2. Milestones

### M1: Entry model — add `displayDomain` field

**Files:** `Feeder/Models/Entry.swift`, `Feeder/FeederApp.swift`

1. Add `var displayDomain: String = ""` to Entry model.
2. Bump `currentSchemaVersion` from `9` to `10` in FeederApp.swift.

**Acceptance:** Project compiles. Database resets on next launch (expected).

### M2: Domain extraction in DataWriter

**Files:** `Feeder/DataWriter.swift`

1. Add a `nonisolated` free function `extractDomain(from:)`:
   ```swift
   nonisolated func extractDomain(from urlString: String) -> String {
     guard let host = URL(string: urlString)?.host() else { return "" }
     return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
   }
   ```
2. At each entry persist site (where `formattedDate` is set), also set:
   ```swift
   entry.displayDomain = extractDomain(from: feed?.siteURL ?? dto.url)
   ```
   Use `feed.siteURL` when available (stable source domain), fall back to entry URL.
3. Apply the same in the seed/demo data generation paths.

**Acceptance:** After sync, entries have populated `displayDomain` values. Verified via debug log or breakpoint.

### M3: Domain pill in EntryRowView (panel 2)

**Files:** `Feeder/Views/EntryRowView.swift`

1. On the second line (currently just `formattedDate`), prepend the domain pill:
   ```swift
   HStack(spacing: 6) {
     if !entry.displayDomain.isEmpty {
       Text(entry.displayDomain)
         .font(.system(size: FontTheme.pillSize, weight: .medium))
         .foregroundStyle(Color(hex: 0xE8654A))
     }
     Text(entry.formattedDate)
       .font(.system(size: FontTheme.captionSize))
       .foregroundStyle(.tertiary)
   }
   ```
2. Update preview helper to set `displayDomain` on sample entries (e.g., `"theverge.com"`).

**Acceptance:** Article list rows show coral domain text before the date. Looks good in both light and dark mode.

### M4: Domain pill in EntryDetailView (panel 3)

**Files:** `Feeder/Views/EntryDetailView.swift`

1. In the metadata HStack, add domain pill as the first element (before feed title):
   ```swift
   if !entry.displayDomain.isEmpty {
     Text(entry.displayDomain)
       .font(.system(size: FontTheme.pillSize, weight: .medium))
       .foregroundStyle(Color(hex: 0xE8654A))
   }
   ```
   Result order: `domain.tld` · `Feed Title` · `Author` · `Timestamp`
2. Update preview to set `displayDomain`.

**Acceptance:** Detail header shows coral domain before feed name.

### M5: Open in browser toolbar button

**Files:** `Feeder/Views/ContentView.swift`

1. Add `.toolbar` modifier to `EntryDetailView` in `detailView`:
   ```swift
   EntryDetailView(entry: selectedEntry)
     .toolbar {
       ToolbarItem(placement: .automatic) {
         Button {
           openInBackground()
         } label: {
           Label("Open in Browser", systemImage: "safari")
         }
         .help("Open in browser (B)")
       }
     }
   ```
   Note: The toolbar is added in ContentView (where `openInBackground()` lives and `selectedEntry` is accessible), not inside EntryDetailView.

**Acceptance:** Safari icon button visible in toolbar when article is selected. Clicking opens article in background browser. Tooltip shows "Open in browser (B)".

### M6: Build verification & tests

1. Run `bash .claude/scripts/test-all.sh` — all green.
2. Verify zero warnings/errors with build script.

**Acceptance:** All tests pass, zero compiler warnings.

## 3. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Coral color poor contrast in dark mode | Medium | Low | Visual check during M3/M4. Can adjust to adaptive color if needed. |
| `URL(string:)?.host()` returns nil for malformed siteURLs | Low | Low | Falls back to empty string — pill simply won't show. Acceptable degradation. |
| Database reset loses user's read state | Certain | Low | Expected per project rules. Re-sync restores articles. Read state syncs from Feedbin. |
| Toolbar button placement conflicts with other toolbar items | Low | Low | Currently no toolbar items in detail view. |

## 4. Confidence

| Milestone | Confidence | Notes |
|-----------|-----------|-------|
| M1: Entry model | High | Trivial field addition, established pattern |
| M2: DataWriter | High | Same as formattedDate pre-computation |
| M3: EntryRowView pill | High | Simple SwiftUI text styling |
| M4: EntryDetailView pill | High | Same as M3 |
| M5: Toolbar button | High | Standard macOS toolbar pattern |
| M6: Build & tests | High | No architectural changes |

Overall: **High confidence.** All patterns are established in the codebase.

## 5. Quality gates

- [ ] `bash .claude/scripts/test-all.sh` — all green
- [ ] Zero compiler warnings (`bash .claude/scripts/build.sh` or equivalent)
- [ ] Domain pill visible in panel 2 (article list) with coral color
- [ ] Domain pill visible in panel 3 (article detail) before feed name
- [ ] Safari toolbar button visible and functional
- [ ] `B` keyboard shortcut still works
- [ ] Light mode and dark mode visual check
- [ ] `www.` prefix stripped from domains
- [ ] Empty domain gracefully hidden (no empty pill)
