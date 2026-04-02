# Implementation Plan: Article List & Detail Pane UI Redesign

**Date:** 2026-04-02
**Research:** [2026-04-02-ui-article-list-detail-redesign.md](../research/2026-04-02-ui-article-list-detail-redesign.md)
**Branch:** `feat/ui-article-list-detail-redesign`

---

## 1. Scope

Redesign two of the three panels in the main NavigationSplitView:

**Panel 2 — Article List:** Transform the minimal row layout into a rich, scannable list matching the Feedbin macOS reference design. Add favicons, summary excerpts, date section headers, and repositioned time display.

**Panel 3 — Article Detail:** Replace the default ArticleBlock (structured SwiftUI) rendering with a WKWebView-based HTML renderer that shows the feed's original HTML with our own CSS applied. Keep ArticleBlock as a "reader" mode, toggled with "R" keyboard shortcut and toolbar button.

**Why:** The current UI is functional but visually sparse. These changes bring the app to parity with established RSS readers (Feedbin, NetNewsWire, Reeder) for daily-driver quality during dogfooding.

---

## 2. Milestones

### M1: Favicon Data Pipeline

**Goal:** Fetch and store favicon URLs from Feedbin Icons API, display in rows.

**Files to modify:**
- `Feeder/FeedbinAPI/FeedbinModels.swift` — add `FeedbinIcon` DTO
- `Feeder/FeedbinAPI/FeedbinClient.swift` — add `fetchIcons()` method
- `Feeder/Models/Feed.swift` — add `faviconURL: String?` field
- `Feeder/DataWriter.swift` — add `syncIcons(_:)` method that matches host→Feed
- `Feeder/FeedbinAPI/SyncEngine.swift` — call icon fetch after subscriptions sync
- `Feeder/FeederApp.swift` — bump `currentSchemaVersion` to 12

**Implementation details:**
1. `FeedbinIcon`: `nonisolated struct FeedbinIcon: Decodable, Sendable { let host: String; let url: String }`
2. `fetchIcons()`: `GET /v2/icons.json` → `[FeedbinIcon]`. Simple endpoint, no pagination.
3. `Feed.faviconURL`: Optional String. Matched via `URL(string: feed.siteURL)?.host()` against `icon.host`.
4. In `SyncEngine.sync()`, after `writer.syncFeeds(subscriptions)`: fetch icons, pass to `writer.syncIcons(icons)`.
5. `syncIcons` fetches all feeds, builds host→faviconURL dictionary, updates matching feeds.

**Acceptance criteria:**
- [ ] After sync, `Feed.faviconURL` is populated for feeds that have Feedbin icons
- [ ] Schema version bumped, app handles fresh reset correctly
- [ ] Zero build warnings

---

### M2: Article List Row Redesign

**Goal:** Redesign `EntryRowView` to match the Feedbin reference screenshot layout.

**Files to modify:**
- `Feeder/Views/EntryRowView.swift` — complete row layout redesign
- `Feeder/Views/FontTheme.swift` — add new size constants if needed

**New row layout (top to bottom):**
```
┌─────────────────────────────────────┐
│ 🌐 MOBILEGAMER.BIZ            19.18│  ← favicon + uppercase feed name (accent) + time (tertiary, right-aligned)
│ Goat Simulator maker Coffee Stain   │  ← title (bold if unread, up to 2 lines)
│ to close its mobile studio           │
│ Coffee Stain is closing its mobile  │  ← summary excerpt (tertiary, 1-2 lines, truncated)
│ developme...                         │
└─────────────────────────────────────┘
```

**Implementation details:**
1. Top row: `HStack` with favicon `AsyncImage` (16×16, rounded 3px), uppercase feed name (`entry.feed?.title` or `entry.displayDomain`), `Spacer`, time-only string.
2. Title: same as current but remove unread dot (unread state shown via font weight + opacity).
3. Summary: `entry.summary` or first ~120 chars of `entry.plainText`, 2-line limit, tertiary color.
4. Unread indicator: instead of blue dot, use font weight (semibold vs regular) and color opacity (primary vs tertiary) — matching reference design which has no dots.
5. Favicon fallback: if `feed.faviconURL` is nil, show a colored circle with the first letter of the feed title (initials icon).
6. Time format: extract time-only from `entry.publishedAt` using a simple `DateFormatter` with `HH.mm` format. This is lightweight — a single formatter instance shared via static property.

**Acceptance criteria:**
- [ ] Row shows favicon, uppercase feed name, time (right), title, summary
- [ ] Unread/read states visually distinct without blue dot
- [ ] Favicon fallback (initials) works when `faviconURL` is nil
- [ ] Existing accessibility labels updated
- [ ] Zero build warnings

---

### M3: Date Section Headers in Article List

**Goal:** Group articles by calendar day with section headers like "YESTERDAY", "TUESDAY 31. MARCH 2026".

**Files to modify:**
- `Feeder/Views/ContentView.swift` — modify `EntryListView` to group entries into sections

**Implementation details:**
1. In `EntryListView.body`, group `entries` by calendar day using `Calendar.current.startOfDay(for: entry.publishedAt)`.
2. Compute section label: "TODAY", "YESTERDAY", or "WEEKDAY D. MONTH YYYY" (uppercase).
3. Use SwiftUI `Section(header:)` with styled `Text`.
4. Section headers: uppercase, small font (`FontTheme.captionSize`), tertiary color, left-aligned.
5. Grouping is O(n) in-memory — acceptable for hundreds of entries per category.

**Key consideration:** `@Query` returns a flat `[Entry]`. We group in the view body. This is fine because:
- Entry counts per category are bounded (typically 50-500)
- SwiftUI `List` with `Section` is optimized for this pattern
- No schema change needed

**Acceptance criteria:**
- [ ] Articles grouped by day with section headers
- [ ] Today → "TODAY", yesterday → "YESTERDAY", older → "WEEKDAY D. MONTH YYYY"
- [ ] Headers are uppercase, small, tertiary color
- [ ] Empty sections not shown
- [ ] Zero build warnings

---

### M4: Article Detail Header Redesign

**Goal:** Redesign the detail view header to match the reference: date+time at top, large title, author+domain below.

**Files to modify:**
- `Feeder/Views/EntryDetailView.swift` — redesign header section

**New header layout:**
```
WEDNESDAY 1. APRIL 2026 AT 19.18      ← small uppercase, accent color

Goat Simulator maker Coffee            ← large bold title
Stain to close its mobile studio

NEIL LONG                              ← author (uppercase, accent color)
MOBILEGAMER.BIZ                        ← domain (uppercase, secondary)
───────────────────────────────────    ← divider
[article body]
```

**Implementation details:**
1. Date+time header: format `entry.publishedAt` as "WEEKDAY D. MONTH YYYY AT HH.MM", uppercase, `FontTheme.captionSize`, accent color.
2. Title: same large bold style, no change.
3. Author + domain: stacked vertically, uppercase, accent/secondary colors.
4. Remove the current inline `HStack` metadata layout.

**Acceptance criteria:**
- [ ] Header matches reference design layout
- [ ] Date, author, domain all uppercase
- [ ] Accent color for date and author
- [ ] Zero build warnings

---

### M5: WKWebView Article Renderer

**Goal:** Create a WKWebView-based article renderer as the default detail view mode.

**New files:**
- `Feeder/Views/ArticleWebView.swift` — `NSViewRepresentable` wrapping `WKWebView`
- `Feeder/Resources/article-template.html` — HTML template with placeholders
- `Feeder/Resources/article-style.css` — our CSS for article rendering
- `Feeder/Resources/article-strip.js` — JavaScript to strip feed CSS

**Implementation details:**

**ArticleWebView (NSViewRepresentable):**
1. Create a reusable `WKWebView` instance via `Coordinator` to avoid recreating on every article change.
2. `updateNSView` loads new HTML content when the entry changes (compare by `feedbinEntryID`).
3. HTML is assembled from template: inject `[[style]]` (our CSS), `[[body]]` (entry.bestHTML), `[[title]]`, `[[date]]`, `[[author]]`, `[[domain]]`.
4. Load via `webView.loadHTMLString(html, baseURL: URL(string: entry.url))` — base URL enables relative image/link resolution.
5. Intercept navigation: `WKNavigationDelegate` opens external links in the system browser (not in the WebView).
6. Disable JavaScript execution from feed content for security (only our injected scripts run).

**HTML Template (`article-template.html`):**
```html
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width">
  <style>[[style]]</style>
</head>
<body>
  <article>
    <header>
      <time>[[date]]</time>
      <h1>[[title]]</h1>
      <div class="byline">
        <span class="author">[[author]]</span>
        <span class="domain">[[domain]]</span>
      </div>
    </header>
    <div class="content">[[body]]</div>
  </article>
  <script>[[strip_js]]</script>
</body>
</html>
```

**CSS (`article-style.css`):**
- System font stack (`-apple-system, BlinkMacSystemFont, ...`)
- Max-width: 44em, centered
- `prefers-color-scheme` media query for dark mode
- Responsive images: `img { max-width: 100%; height: auto; }`
- Link styling matching our accent color (`#E8654A`)
- Typography: line-height 1.6, comfortable reading size
- Header styling: date uppercase small accent, title large bold, byline accent/secondary

**JavaScript (`article-strip.js`):**
Inspired by NetNewsWire's `stripStyles()`:
1. Remove all `<link rel="stylesheet">` elements
2. Remove inline `style` attributes that set color, background, font-family, font-size, width, height, position
3. Preserve structural styles (display, margin, padding — only if they don't break layout)
4. Remove `<script>` tags from feed content (security)

**Acceptance criteria:**
- [ ] Articles render with rich HTML (images, links, formatting)
- [ ] Feed CSS stripped, our CSS applied
- [ ] Dark mode works via `prefers-color-scheme`
- [ ] External links open in system browser
- [ ] Images render responsively
- [ ] WebView instance reused across article changes (no flicker/reload)
- [ ] Zero build warnings

---

### M6: View Mode Toggle (R Key + Toolbar Button)

**Goal:** Toggle between WKWebView (HTML) and ArticleBlockView (reader/plaintext) modes.

**Files to modify:**
- `Feeder/Views/EntryDetailView.swift` — add view mode state and toggle
- `Feeder/Views/ContentView.swift` — add "R" keyboard shortcut, toolbar button

**Implementation details:**
1. Add `@State private var viewMode: ArticleViewMode = .web` enum (`.web`, `.reader`).
2. In `EntryDetailView`, switch on `viewMode`:
   - `.web` → `ArticleWebView(entry:)` with redesigned header (from M4)
   - `.reader` → existing `ArticleBlockView(blocks:)` with existing header
3. "R" keyboard shortcut in `ContentView` toggles `viewMode` (only when `selectedEntry != nil`).
4. Toolbar button: `Image(systemName: "doc.richtext")` / `Image(systemName: "doc.plaintext")` toggle.
5. View mode state resets to `.web` when `selectedEntry` changes.

**Note:** The header from M4 is part of the HTML template in `.web` mode. In `.reader` mode, the SwiftUI header remains. Both show the same information in the same layout — just rendered differently.

**Acceptance criteria:**
- [ ] "R" key toggles between web and reader mode
- [ ] Toolbar button toggles and reflects current mode
- [ ] Mode resets to `.web` on article change
- [ ] Both modes render article content correctly
- [ ] Keyboard shortcut only active when article is selected
- [ ] Zero build warnings

---

## 3. Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| **WKWebView lifecycle in SwiftUI** — recreated on state changes, causing flicker | High | Medium | Use `Coordinator` to hold WKWebView instance; only update content in `updateNSView` |
| **Keyboard shortcut "R" captured by WKWebView** — WebView may consume key events | Medium | Medium | Use SwiftUI `.onKeyPress` at `ContentView` level (above WebView); test focus behavior |
| **Feed HTML quality** — malformed HTML breaks rendering | Low | Low | WKWebView has browser-grade tolerance; template wrapping provides safety net |
| **Favicon coverage gaps** — many feeds without icons | Medium | Medium | Initials fallback icon (colored circle + letter) provides visual consistency |
| **Schema version bump** — forces full resync for existing users | Low | Certain | Expected and acceptable (app auto-resets on version mismatch, resync takes <1 min) |
| **Dark mode CSS** — some feed images/content look wrong in dark mode | Medium | Medium | `prefers-color-scheme` handles base styling; feed images are unmodified |

---

## 4. Confidence

| Milestone | Confidence | Notes |
|-----------|------------|-------|
| M1: Favicon Data Pipeline | **High** | Standard API integration, well-documented Feedbin endpoint |
| M2: Article List Row Redesign | **High** | Pure SwiftUI layout work, clear reference design |
| M3: Date Section Headers | **High** | Simple grouping logic, standard SwiftUI Section |
| M4: Article Detail Header | **High** | SwiftUI layout, no new dependencies |
| M5: WKWebView Article Renderer | **Medium** | New dependency (WebKit), AppKit bridging, CSS/JS authoring. Most complex milestone. |
| M6: View Mode Toggle | **High** | Simple state management, standard keyboard/toolbar patterns |

---

## 5. Quality Gates

### Before PR

- [ ] `bash .claude/scripts/test-all.sh` — ALL GREEN
- [ ] `xcodebuild build` — zero errors, zero warnings
- [ ] Manual verification: favicon appears for at least one feed after sync
- [ ] Manual verification: date sections display correctly (today, yesterday, older)
- [ ] Manual verification: WKWebView renders an article with images and links
- [ ] Manual verification: "R" toggles between web and reader mode
- [ ] Manual verification: dark mode renders correctly in both modes
- [ ] Manual verification: external links in WebView open in system browser

### Code Quality

- [ ] Swift 6 strict concurrency: zero warnings
- [ ] No `@Model` objects crossing actor boundaries
- [ ] All writes through `DataWriter`
- [ ] No `DispatchQueue`/GCD/locks
- [ ] WebView content loading is non-blocking (async)
- [ ] Favicon `AsyncImage` uses appropriate placeholder/fallback

### PR Requirements

- [ ] Single PR with all 6 milestones
- [ ] Conventional commit messages per milestone
- [ ] `/codereview` passes
- [ ] User tested in Xcode before merge
