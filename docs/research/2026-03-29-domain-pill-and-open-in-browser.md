# Research: Domain Pill Badge & Open in Browser UX

Date: 2026-03-29
Analyst: Claude (research agent)

## 1. Problem

Two UX gaps in the current Feeder app:

**A) No source visibility in article list or detail views.** Users cannot quickly see which website an article comes from without opening the detail panel and reading the feed title. A compact domain badge (e.g., `theverge.com`) would provide instant source recognition.

**B) No visible way to open articles in an external browser.** The `B` keyboard shortcut exists (`openInBackground()` in ContentView.swift:246-260) but is undiscoverable — there is no button or visual affordance in the UI.

### Requested changes

1. **Domain pill** in panel 2 (EntryRowView): show `domain.tld` on the second line, before the timestamp, in a highlight color (warm orange-red).
2. **Domain pill** in panel 3 (EntryDetailView): show `domain.tld` on the metadata line, before the feed title.
3. **"Open in browser" button** in panel 3 toolbar/header area.
4. **Keyboard shortcut `B`** already exists — no change needed, just ensure discoverability via the button tooltip.

## 2. Constraints

### Technical

- **Swift 6 strict concurrency** — all UI code is MainActor-isolated. Domain extraction must be pure/nonisolated.
- **Two-layer architecture** — display values should be pre-computed at write time in DataWriter, not computed during rendering.
- **@Query filtering** — no Swift-side filtering of query results. Domain pill is display-only, not filterable, so this is not a concern.
- **Entry model** — adding a new persisted field (`displayDomain: String`) requires bumping `currentSchemaVersion` in FeederApp.swift.
- **Feed.siteURL** is available on the Feed model (e.g., `"https://theverge.com"`). Entry.url is the article permalink. Either can be used to derive the domain, but Feed.siteURL is more stable and representative of the source.

### Design

- Pill must be compact — fits on the same line as timestamp in panel 2.
- Color must work in both light and dark mode.
- "Open in browser" button must not clutter the reading experience.

## 3. Alternatives

### A) Domain extraction approach

| Option | Pros | Cons |
|--------|------|------|
| **A1: Pre-compute `displayDomain` on Entry at persist time** | Zero runtime cost in UI. Consistent with existing `formattedDate` pattern. Works in @Query sort/display. | Requires schema migration (version bump). Adds ~15 bytes per entry. |
| **A2: Compute domain from `entry.feed?.siteURL` at render time** | No schema change. Always up-to-date if feed URL changes. | Requires accessing Feed relationship during render. Minor but breaks the "pre-compute display fields" principle. |
| **A3: Pre-compute `displayDomain` on Feed model** | One field per feed instead of per entry. Natural home for feed-level metadata. | Requires Feed schema change. EntryRowView would need feed relationship access (it currently only uses Entry). |

**Recommendation: A1** — aligns with the established pattern (`formattedDate` is pre-computed the same way). The schema auto-resets on version mismatch, so no migration needed.

### B) Domain formatting: `www.theverge.com` → `theverge.com`

Standard approach: strip `www.` prefix from URL host. Use `URL(string:)?.host()` then remove leading `www.`.

Source preference: Use `entry.feed?.siteURL` when available (represents the publication), fall back to `entry.url` (article permalink). Both should yield the same domain in most cases.

### C) Pill styling

| Option | Pros | Cons |
|--------|------|------|
| **C1: Text-only pill with color** | Simple, compact, consistent with existing caption style. | Less visually distinct. |
| **C2: Capsule background badge** | Highly visible, looks like a tag/chip. Modern UI pattern. | May feel heavy in a dense list. Needs careful color tuning for dark mode. |
| **C3: Text with leading dot/icon** | Subtle visual separator. Lightweight. | Less recognizable as a "source" indicator. |

**Recommendation: C1 for panel 2** (text-only with warm color, keeping the row lightweight), **C2 for panel 3** (capsule badge, more space available in detail header). However, consistent treatment (both C1 or both C2) is also valid — user preference.

### D) Color choice

Requested: "sopiva oranssinpunainen" (suitable orange-red).

| Option | Hex | Notes |
|--------|-----|-------|
| **Coral/Salmon** | `#E8654A` | Warm, readable on both light/dark. Similar to RSS icon color tradition. |
| **Burnt Orange** | `#D4652F` | Slightly warmer, good contrast. |
| **Muted Red-Orange** | `#C75B39` | Deeper, more subdued. |

All should be defined as a `Color` constant, ideally in an asset catalog or as a static `Color(hex:)` extension (which already exists in the codebase per `Color(hex: 0x5A9CFF)` in EntryRowView).

**Recommendation: `#E8654A` (Coral)** — warm, distinctive, good contrast ratio in both modes.

### E) "Open in browser" button placement

| Option | Pros | Cons |
|--------|------|------|
| **E1: Toolbar button in detail panel (.toolbar)** | Standard macOS pattern. Non-intrusive. | May be far from content. Toolbar space can get crowded. |
| **E2: Inline button in metadata row** | Close to source info. Contextually appropriate. | Adds visual weight to metadata line. |
| **E3: Floating button in top-right corner** | Always visible. Easy to discover. | Overlaps scroll content. Non-standard. |

**Recommendation: E1** — toolbar button with `safari` SF Symbol. Standard macOS idiom. Tooltip should mention `⌘B` or `B` shortcut for discoverability.

Note: The current `B` shortcut uses `.onKeyPress` without modifier keys. A toolbar button can simply call the same `openInBackground()` method. Consider whether it should open in foreground (toolbar click) vs background (keyboard shortcut), or if both should behave the same.

## 4. Evidence

### Current codebase state

- **EntryRowView** (`Feeder/Views/EntryRowView.swift`): Two-line layout — title (line 1), formattedDate (line 2). No feed/source info shown.
- **EntryDetailView** (`Feeder/Views/EntryDetailView.swift`): Metadata HStack — feedTitle, author, timestamp. No domain badge. No open-in-browser button.
- **Entry model** (`Feeder/Models/Entry.swift`): Has `url: String`, `feed: Feed?` relationship. No `displayDomain` field.
- **Feed model** (`Feeder/Models/Feed.swift`): Has `siteURL: String` (e.g., `"https://theverge.com"`).
- **FontTheme** (`Feeder/Views/FontTheme.swift`): Already has `pillSize: CGFloat = baseSize - 1` (14pt). This was likely added anticipating pill-style badges.
- **Keyboard shortcut** (`ContentView.swift:218-221`): `B` key already triggers `openInBackground()`. Opens URL without activating browser window.
- **Color extension**: `Color(hex:)` init exists (used in EntryRowView line 17).

### Pre-computation pattern

DataWriter already pre-computes `formattedDate` at persist time (DataWriter.swift). The same pattern applies to `displayDomain`:

```swift
// In DataWriter, during entry persist:
entry.displayDomain = extractDomain(from: feed.siteURL)
```

### Domain extraction logic

```swift
nonisolated func extractDomain(from urlString: String) -> String {
  guard let host = URL(string: urlString)?.host() else { return "" }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}
```

This is pure, Sendable-safe, and can live as a free function or static method.

## 5. Unknowns

1. **Dark mode color tuning** — The coral color (`#E8654A`) needs visual verification in both appearances. May need a semantic color with light/dark variants.
2. **Entry.url vs Feed.siteURL domain mismatch** — Some feeds serve articles from subdomains (e.g., `blog.example.com` vs `example.com`). Need to decide which URL to use as source. Feed.siteURL is more consistent but may not match the article's actual domain.
3. **Existing entries** — After schema version bump, the database resets. All existing entries lose their data and need re-sync. This is acceptable per project rules ("Database auto-resets on version mismatch. Never write migrations.").

**Biggest risk:** #1 — color accessibility. A single hex color may not have sufficient contrast in both light and dark modes. Mitigation: use an adaptive Color asset or conditional color based on colorScheme.

## 6. Recommendation

**Evidence is sufficient to proceed to planning.** The implementation is well-scoped:

1. Add `displayDomain: String` to Entry model + bump schema version.
2. Add domain extraction in DataWriter at persist time.
3. Add domain pill to EntryRowView (before timestamp, coral text color).
4. Add domain pill to EntryDetailView (before feed title, coral text color).
5. Add toolbar button with safari icon in EntryDetailView.
6. Existing `B` keyboard shortcut needs no changes.

Estimated complexity: **SMALL-to-MEANINGFUL** — touches 5-6 files, schema change, but no architectural changes. The patterns are all established.
