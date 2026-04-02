# Research: Article List & Detail Pane UI Redesign

**Date:** 2026-04-02
**Scope:** Two UI changes — (1) article list redesign with favicons and date sections, (2) article detail HTML rendering with WKWebView

---

## 1. Problem

### Panel 2 — Article List
The current article list (`EntryRowView`) shows minimal information per row: title, domain text, and a pre-formatted date. Compared to the reference design (Feedbin macOS app), we are missing:
- **Favicons** — no feed icon shown, making it harder to visually scan by source
- **Summary preview** — no excerpt text below the title
- **Date section headers** — no "YESTERDAY", "TUESDAY 31. MARCH 2026" grouping
- **Feed name label** — domain shown as plain text, not as uppercase branded label
- **Time positioning** — date/time is inline with domain, not in top-right corner

### Panel 3 — Article Detail
The current detail view (`EntryDetailView`) renders articles through `ArticleBlock` — a custom SwiftUI block renderer that converts HTML to structured blocks at persist time. This:
- Loses HTML formatting nuance (tables, embedded media, complex layouts)
- Cannot render the original article's rich HTML content faithfully
- Has no way to toggle between a clean reader view and the feed's HTML

The reference design shows rich HTML content (images, links, typography) rendered inline, similar to how NetNewsWire uses WKWebView.

---

## 2. Constraints

### Technical
- **Swift 6 strict concurrency** — all new code must compile with zero warnings
- **Two-layer architecture** — UI layer is MainActor/read-only, data layer is background
- **SwiftData `@Query`** — list filtering/sorting must stay in SQLite predicates
- **No `@Model` across actors** — use `PersistentIdentifier` for cross-boundary references
- **macOS only** — can use AppKit/WKWebView without iOS compatibility concerns

### Data Model
- `Feed` model has `siteURL` but no `faviconURL` field — needs schema change + version bump
- `Entry` already has `bestHTML` computed property (extractedContent > content > summary)
- `Entry.content` stores the original feed HTML — available for WebView rendering
- `Entry.formattedDate` is pre-computed at persist time — format needs changing for new layout

### API
- Feedbin provides `/v2/icons.json` endpoint returning `{host, url}` pairs
- Icons are 32x32 PNG, hosted on `favicons.feedbinusercontent.com`
- Matching is by host (e.g., `github.blog`), not by feed ID

### Performance
- Date section grouping must not happen in SwiftUI rendering — needs to be computed efficiently
- Favicon images should be cached (AsyncImage or URLCache)
- WKWebView has higher memory footprint than native SwiftUI rendering

---

## 3. Alternatives

### Panel 2 — Favicon Source

| Option | Pros | Cons |
|--------|------|------|
| **A: Feedbin Icons API** | Pre-processed 32x32 PNG, CDN-hosted, no extra deps | Requires auth, only covers Feedbin feeds, host-based matching |
| **B: DuckDuckGo favicon service** | No auth needed, works for any domain | External dependency, no SLA, variable quality |
| **C: Direct /favicon.ico fetch** | No third-party dependency | Unreliable, variable formats (ICO/PNG/SVG), needs conversion |

**Recommendation: Option A (Feedbin Icons API)** with fallback to generated initials icon (no external service dependency).

### Panel 2 — Date Sectioning

| Option | Pros | Cons |
|--------|------|------|
| **A: Compute sections in SwiftUI from @Query results** | Simple, uses existing query | O(n) grouping in rendering code, re-computes on every state change |
| **B: Store section key in Entry model** | Queryable, pre-computed | Schema change, stale if timezone changes, another denormalized field |
| **C: Use SwiftUI `Section` with computed grouping in the view model** | Clean separation, computed once per data change | Requires grouping logic outside @Query |

**Recommendation: Option A** — group `@Query` results by calendar day in the view. Entry count per category is bounded (hundreds, not thousands), so in-memory grouping is acceptable. This avoids schema changes for a display-only concern.

### Panel 3 — HTML Rendering

| Option | Pros | Cons |
|--------|------|------|
| **A: WKWebView with HTML template + CSS injection** (NetNewsWire approach) | Faithful HTML rendering, supports images/tables/embeds, proven pattern | Higher memory, needs WKWebView lifecycle management, AppKit/SwiftUI bridging |
| **B: Enhance ArticleBlock to support more HTML elements** | Pure SwiftUI, no WebView overhead | Endless edge cases, will never match real HTML rendering, significant effort |
| **C: SwiftUI `Text` with `AttributedString` from HTML** | Lightweight | Very limited HTML support, no images, no tables |

**Recommendation: Option A** — WKWebView is the industry standard for RSS article rendering (used by NetNewsWire, Reeder, Feedbin web). The current ArticleBlock view becomes the "reader/plaintext" mode, and WKWebView becomes the default HTML mode. Toggle with "R" key.

---

## 4. Evidence

### Feedbin Icons API
- **Endpoint:** `GET /v2/icons.json` (authenticated)
- **Response:** Array of `{host: String, url: String}` — e.g., `{"host": "github.blog", "url": "https://favicons.feedbinusercontent.com/19a/...png"}`
- **Source:** [feedbin-api/icons.md](https://github.com/feedbin/feedbin-api/blob/master/content/icons.md)
- **Matching:** `URL(string: feed.siteURL)?.host()` → match against `icon.host`

### NetNewsWire HTML Rendering Architecture
- Uses `WKWebView` on both macOS and iOS
- **HTML template system:** `template.html` with `[[style]]`, `[[body]]`, `[[title]]` placeholders
- **CSS stripping:** JavaScript `stripStyles()` in `main.js` removes `<link rel="stylesheet">` and inline `style` attributes for color/background/font/sizing
- **Own CSS injection:** `stylesheet.css` provides layout (max-width 44em, system fonts, dark/light mode via `prefers-color-scheme`, responsive images)
- **Content blocking:** WebKit content rules block 34 ad/tracking domains
- **Key files:** `Shared/Article Rendering/ArticleRenderer.swift`, `main.js`, `stylesheet.css`, `template.html`

### Reference Design (Feedbin macOS App — from screenshot)
**Panel 2 layout per row:**
- Uppercase feed name label (e.g., "MOBILEGAMER.BIZ") in orange/accent color — top left
- Favicon (small, ~16px) inline with feed name
- Time only (e.g., "19.18") — top right, small, tertiary color
- Title — bold, up to 2 lines
- Summary excerpt — lighter text, 1-2 lines, truncated with "..."

**Panel 2 section headers:**
- Date headers: "YESTERDAY", "TUESDAY 31. MARCH 2026", "MONDAY 30. MARCH 2026"
- Uppercase, small font, tertiary color, left-aligned

**Panel 3 layout:**
- Date + time header at top (e.g., "WEDNESDAY 1. APRIL 2026 AT 19.18") — small, uppercase, accent color
- Large article title
- Author name + domain in accent/secondary color
- Rich HTML body with images, links, paragraphs
- Clean typography, max-width constrained, comfortable reading width

### Current Codebase State
- `EntryRowView.swift` — minimal row: unread dot, title, domain+date inline
- `EntryDetailView.swift` — ArticleBlock rendering, metadata header, 610px max width
- `ArticleBlockView.swift` — SwiftUI block renderer (paragraphs, headings, images, code, lists, blockquotes)
- `HTMLToBlocks.swift` — HTML→ArticleBlock parser, strips scripts/styles/nav
- `ContentView.swift` — keyboard shortcuts: Escape (clear), B (open in browser)
- `FontTheme.swift` — centralized sizing, `domainPillColor = #E8654A`
- No WKWebView, no favicon fetching, no date sectioning anywhere in codebase

---

## 5. Unknowns

### Favicon Coverage
- **Unknown:** What percentage of the user's feeds have icons in Feedbin's Icons API?
- **Mitigation:** Implement a fallback — show a generated icon with the first letter(s) of the feed name in a colored circle (similar to contact initials).

### WKWebView + SwiftUI Integration
- **Unknown:** How well does `WKWebView` integrate with SwiftUI's `NavigationSplitView` detail pane on macOS? Potential issues with focus, keyboard events, and sizing.
- **Mitigation:** Use `NSViewRepresentable` wrapper. NetNewsWire uses AppKit directly, but SwiftUI bridging is well-documented for macOS.

### HTML Content Quality
- **Unknown:** How much of the feed HTML content is well-formed? Malformed HTML could cause rendering issues in WKWebView.
- **Mitigation:** WKWebView is tolerant of malformed HTML (browser-grade parser). NetNewsWire's approach of wrapping content in a template provides a safety net.

### Keyboard Shortcut "R" Conflicts
- **Unknown:** Does "R" conflict with any system or existing shortcuts?
- **Current shortcuts:** Only Escape and B are registered. "R" is available.

### ⚠️ Biggest Risk: WKWebView Lifecycle in SwiftUI
WKWebView is heavyweight — creating/destroying it on every article selection could cause performance issues (memory, load time). NetNewsWire reuses a single WebView instance and updates its content. In SwiftUI with `NavigationSplitView`, the detail view may be recreated on selection changes. Need to ensure the WebView instance is reused, not recreated.

---

## 6. Recommendation

**Evidence is sufficient to proceed to planning.** No additional research needed.

### Suggested Implementation Scope (two work streams)

**Stream 1 — Panel 2 Redesign:**
1. Add `faviconURL: String?` to `Feed` model (schema version bump)
2. Add `FeedbinIcon` DTO and `fetchIcons()` to `FeedbinClient`
3. Store favicon URLs during sync in `DataWriter`
4. Redesign `EntryRowView`: favicon, uppercase feed name, summary, time top-right
5. Add date section headers to `EntryListView`
6. Update `formattedDate` format (time-only for row, full date for sections)

**Stream 2 — Panel 3 HTML Rendering:**
1. Create `ArticleWebView` (`NSViewRepresentable` wrapping `WKWebView`)
2. Create HTML template + CSS (inspired by NetNewsWire, matching our visual style)
3. Add JavaScript for CSS stripping from feed content
4. Integrate into `EntryDetailView` as default view mode
5. Keep `ArticleBlockView` as "reader/plaintext" mode
6. Add "R" keyboard shortcut to toggle between modes
7. Add toolbar toggle button
8. Redesign detail header to match reference (date + title + author layout)
