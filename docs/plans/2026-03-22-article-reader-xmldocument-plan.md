# Plan: Article Reader — XMLDocument + ArticleBlock

Date: 2026-03-22
Supersedes: `2026-03-21-article-reader-plan.md`
Research: `docs/research/2026-03-22-article-reader-xmldocument-architecture.md`
Branch: `feat/article-reader`

## Scope

Render article body as structured blocks using Foundation XMLDocument.
Zero external dependencies. Pre-parse HTML at persist time for instant display.

## Architecture

```
Persist (DataWriter, background @ModelActor):
  bestHTML → XMLDocument(.documentTidyHTML) → walk DOM → [ArticleBlock] → JSON → articleBlocks field

Display (MainActor):
  articleBlocks JSON → decode [ArticleBlock] → ForEach → SwiftUI views

Classification:
  [ArticleBlock].classificationText → plain text for LLM
```

## Implementation Steps

### Step 1: ArticleBlock enum

**New file: `Feeder/Models/ArticleBlock.swift`**

```swift
enum ArticleBlock: Codable, Sendable {
    case paragraph(text: String)           // inline Markdown in text
    case heading(level: Int, text: String)
    case image(url: String, alt: String)
    case codeBlock(code: String)
    case list(ordered: Bool, items: [String])
    case blockquote(text: String)
    case divider
}
```

Plus `classificationText` computed property on `[ArticleBlock]`.

### Step 2: HTML→Blocks converter

**New file: `Feeder/Helpers/HTMLToBlocks.swift`**

`nonisolated func parseHTMLToBlocks(_ html: String) -> [ArticleBlock]`

- Parse with `XMLDocument(xmlString:, options: .documentTidyHTML)`
- Walk DOM tree recursively
- Whitelist: `p, h1-h6, img, ul, ol, li, blockquote, pre, code, hr, figure, figcaption`
- Blacklist (skip entirely): `script, style, noscript, nav, footer, header, aside, form, iframe`
- Containers (recurse into): `div, section, article, span, main`
- Inline→Markdown: `strong/b→**`, `em/i→*`, `a→[text](href)`, `code→backtick`
- Fallback: return `[.paragraph(text: stripHTMLToPlainText(html))]` on parse error

### Step 3: Entry model — add articleBlocks field

**File: `Feeder/Models/Entry.swift`**

Add: `var articleBlocks: Data?` — stored as JSON-encoded `[ArticleBlock]`

Add computed accessors:
```swift
var parsedBlocks: [ArticleBlock] { decode articleBlocks or fallback }
```

### Step 4: DataWriter — compute articleBlocks at persist time

**File: `Feeder/DataWriter.swift`**

At all 3 persist/update sites, add:
```swift
entry.articleBlocks = encodeBlocks(parseHTMLToBlocks(bestHTML))
```

Update `fetchUnclassifiedInputs()` to use `parsedBlocks.classificationText` instead of `plainText`.

### Step 5: Schema version bump

**File: `Feeder/FeederApp.swift`** — `currentSchemaVersion = 6` → `7`

### Step 6: ArticleBlockView — SwiftUI renderer

**New file: `Feeder/Views/ArticleBlockView.swift`**

Maps each ArticleBlock to SwiftUI:
- `.paragraph` → `Text(markdown:)` with body font + line spacing
- `.heading` → `Text()` with scaled font per level
- `.image` → `AsyncImage` with max-width, rounded corners, placeholder
- `.codeBlock` → monospace `Text` with subtle background
- `.list` → `VStack` with bullet/number prefix
- `.blockquote` → text with leading accent border
- `.divider` → `Divider()`

### Step 7: EntryDetailView — wire up

**File: `Feeder/Views/EntryDetailView.swift`**

Replace `Text(current.plainText)` with `ArticleBlockView(blocks: current.parsedBlocks)`.

### Step 8: Build verification

```bash
bash .claude/scripts/build-for-testing.sh
```

## Files Changed

| File | Change |
|------|--------|
| `Feeder/Models/ArticleBlock.swift` | **New** — block enum + classificationText |
| `Feeder/Helpers/HTMLToBlocks.swift` | **New** — XMLDocument DOM walker |
| `Feeder/Views/ArticleBlockView.swift` | **New** — SwiftUI block renderer |
| `Feeder/Models/Entry.swift` | Add `articleBlocks` field + `parsedBlocks` accessor |
| `Feeder/DataWriter.swift` | Compute blocks at persist time, update classification |
| `Feeder/FeederApp.swift` | Schema version 6 → 7 |
| `Feeder/Views/EntryDetailView.swift` | Use ArticleBlockView |

## Dependencies

**None.** All Foundation + SwiftUI.
