# Plan: Article Reader — Markdown Rendering

Date: 2026-03-21
Research: `docs/research/2026-03-21-article-reader-markdown-rendering.md`
Branch: `feat/article-reader`

## Scope

Convert article body rendering from plain text to styled Markdown. Two phases:
- **Phase 1**: HTML→Markdown conversion + `Text(markdown:)` display (bold, italic, links)
- **Phase 2**: AST-based block renderer (headings, images, lists, code blocks, blockquotes)

This PR delivers **both phases** as a single unit.

## Key Decisions

1. **Reuse `plainText` field** — store Markdown instead of stripped text. No new field, no schema migration. Bump `currentSchemaVersion` to 7 (triggers fresh sync → all articles re-processed).
2. **SwiftHTMLToMarkdown** for HTML→MD conversion (pure Swift, background-actor safe).
3. **apple/swift-markdown** for AST parsing in the renderer.
4. Classification continues to use `plainText` (now Markdown) — works fine for LLM inference.

## Implementation Steps

### Step 1: Add SPM dependencies

Add to Xcode project:
- `SwiftHTMLToMarkdown` — https://github.com/ActuallyTaylor/SwiftHTMLToMarkdown
- `swift-markdown` — https://github.com/swiftlang/swift-markdown

### Step 2: Data layer — HTML→Markdown conversion

**File: `DataWriter.swift`**

Replace `stripHTMLToPlainText()` with a new `convertHTMLToMarkdown()` helper:

```swift
nonisolated func convertHTMLToMarkdown(_ html: String) -> String {
    // Use SwiftHTMLToMarkdown to convert
    // Fallback to stripHTMLToPlainText() on error
}
```

Update all 3 call sites:
- `persistEntries(_:markAsRead:)` line 142
- `persistEntries(_:unreadIDs:)` line 183
- `applyExtractedContent(results:)` line 239

Keep `stripHTMLToPlainText()` as fallback — if conversion fails, degrade gracefully.

### Step 3: Bump schema version

**File: `FeederApp.swift`**

`currentSchemaVersion = 6` → `7`. This triggers article deletion + fresh sync on next launch, so all articles get Markdown bodies.

### Step 4: Phase 1 — Text(markdown:) in EntryDetailView

**File: `EntryDetailView.swift`**

Replace line 71:
```swift
// Before
Text(current.plainText)

// After
Text(LocalizedStringKey(current.plainText))
```

Note: `Text(markdown:)` is actually `Text(LocalizedStringKey(...))` — SwiftUI parses inline Markdown from LocalizedStringKey.

This immediately gives us bold, italic, strikethrough, inline code, and clickable links.

### Step 5: Phase 2 — MarkdownBodyView (AST renderer)

**New file: `Feeder/Views/MarkdownBodyView.swift`**

A SwiftUI view that:
1. Parses Markdown string with `swift-markdown`'s `Document(parsing:)`
2. Walks the AST with a `MarkupWalker` or iterates `Document.children`
3. Emits appropriate SwiftUI views per block type:

| AST Node | SwiftUI Output |
|----------|---------------|
| `Paragraph` | `Text(markdown: inlineContent)` with body font |
| `Heading` | `Text()` with scaled font per level |
| `Image` | `AsyncImage(url:)` with rounded corners, max-width |
| `CodeBlock` | `Text()` + monospace + subtle background |
| `UnorderedList` | `VStack` with `•` prefix per item |
| `OrderedList` | `VStack` with `1.` prefix per item |
| `BlockQuote` | `Text()` + leading accent border + italic |
| `ThematicBreak` | `Divider()` |
| `HTMLBlock` | Skip or render as plain text |
| `Table` | Skip for now (rare in RSS) |

Design principles:
- Match existing `FontTheme` sizes and spacing
- Max content width 660pt (matches current `EntryDetailView`)
- Images: `AsyncImage` with placeholder, max-width constrained, rounded corners
- Links: native SwiftUI link handling (open in default browser)
- Calm palette: no aggressive colors, subtle blockquote borders

### Step 6: Wire MarkdownBodyView into EntryDetailView

Replace the Phase 1 `Text(markdown:)` with:
```swift
MarkdownBodyView(markdown: current.plainText)
```

### Step 7: Build verification

```bash
bash .claude/scripts/build-for-testing.sh 2>&1 | grep -E "(error:|warning:)"
# Must produce zero output
```

## Files Changed

| File | Change |
|------|--------|
| `Feeder.xcodeproj` | Add SPM dependencies |
| `Feeder/DataWriter.swift` | Replace `stripHTMLToPlainText` → `convertHTMLToMarkdown` |
| `Feeder/FeederApp.swift` | Schema version 6 → 7 |
| `Feeder/Views/EntryDetailView.swift` | Use `MarkdownBodyView` |
| `Feeder/Views/MarkdownBodyView.swift` | **New** — AST-based Markdown renderer |
| `Feeder/Views/ContentView.swift` | Update preview data (3 lines) |

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| SwiftHTMLToMarkdown mishandles edge-case HTML | Fallback to `stripHTMLToPlainText()`, test with real Feedbin data |
| AST renderer missing block types | Unknown nodes render as plain text |
| Performance with very long articles | AST parsing is O(n), views are lazy in ScrollView |
| Image loading latency | AsyncImage with placeholder, doesn't block text rendering |

## Out of Scope

- Table rendering (rare in RSS, can add later)
- Video/iframe embeds
- Custom fonts (use system fonts via FontTheme)
- Offline image caching
