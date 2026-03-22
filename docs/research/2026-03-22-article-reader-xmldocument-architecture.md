# Research: Article Reader — XMLDocument Architecture

Date: 2026-03-22
Supersedes: `2026-03-21-article-reader-markdown-rendering.md`
Status: Complete
Decision: Pending user approval

## Context

Previous research recommended SwiftHTMLToMarkdown + swift-markdown (2 external dependencies). Build testing revealed SwiftSoup (transitive dependency) is extremely heavy to compile, making builds unacceptably slow. User asked: can we use Apple's own XMLDocument to parse HTML directly?

## XMLDocument Findings

### What is it?
`XMLDocument` (Foundation, macOS) wraps libxml2 and can parse HTML via `documentTidyHTML` option. It produces a full DOM tree (`XMLElement`/`XMLNode`) that can be walked — exactly like swift-markdown's AST, but for HTML.

### Thread safety
libxml2 is thread-safe for concurrent parsing of **different documents**. `XMLDocument` is not `Sendable` (it's an `NSObject` subclass), but this doesn't matter — we create and consume it within a single function scope in `DataWriter`, never passing it across actor boundaries.

### Performance
libxml2 is ~4x faster than tree-based NSXMLDocument alternatives. For typical RSS article HTML (5–50KB), parsing takes <1ms.

### Platform
macOS only — `XMLDocument` is not available on iOS. Our app is macOS-only, so this is fine.

## Architecture Options

The core question: **where does HTML parsing happen, and what format is stored for display?**

### Option A: Parse HTML at display time (no pre-processing)

```
Persist: store bestHTML as-is (already stored)
Display: bestHTML → XMLDocument → walk DOM → SwiftUI views
```

- **Pro**: No conversion step, no storage overhead, no intermediate format
- **Con**: XMLDocument parsing on MainActor every time article is viewed
- **Performance risk**: Low for typical articles (<1ms parse), but creates coupling between display and parsing
- **Verdict**: Viable but violates our "pre-compute at persist time" principle

### Option B: Pre-convert HTML → Markdown at persist time with XMLDocument

```
Persist: bestHTML → XMLDocument → walk DOM → emit Markdown → store in plainText
Display: plainText (Markdown) → block parser → SwiftUI views
```

- **Pro**: Heavy parsing in background DataWriter, lightweight display
- **Pro**: Markdown is compact, human-readable, easy to debug
- **Con**: Lossy conversion (some HTML constructs don't map cleanly to Markdown)
- **Con**: Still need a Markdown block parser at display time (even if lightweight)
- **Verdict**: Good separation of concerns, but two conversion steps feels over-engineered

### Option C: Pre-convert HTML → structured blocks (JSON) at persist time

```
Persist: bestHTML → XMLDocument → walk DOM → [ArticleBlock] → JSON → store in field
Display: JSON → decode [ArticleBlock] → SwiftUI views
```

Where `ArticleBlock` is:
```swift
enum ArticleBlock: Codable, Sendable {
    case paragraph(text: String)      // text contains inline Markdown
    case heading(level: Int, text: String)
    case image(url: String, alt: String)
    case codeBlock(code: String, language: String?)
    case list(ordered: Bool, items: [String])
    case blockquote(text: String)
    case divider
}
```

- **Pro**: Zero parsing at display time — instant rendering
- **Pro**: Clean typed data, easy to render
- **Pro**: Inline text stored as Markdown → SwiftUI `Text(markdown:)` handles bold/italic/links
- **Con**: Slightly more storage (JSON overhead)
- **Con**: Need to define and maintain ArticleBlock schema
- **Verdict**: ✅ Best fit for our "data ready for display" principle

### Option D: Parse HTML at display time, off MainActor

```
Persist: store bestHTML as-is
Display: user selects article → Task { parse on background } → @State blocks → render
```

- **Pro**: No schema changes, no conversion at persist time
- **Con**: Brief loading state when switching articles (not "instant")
- **Con**: More complex state management in view
- **Verdict**: Violates "instant article reading" requirement

## Recommendation: Option C (structured blocks)

Option C best satisfies both requirements:

1. **MainActor is never heavy** — all HTML parsing happens in `DataWriter` (background `@ModelActor`)
2. **Data is in ready-to-display format** — JSON-encoded `[ArticleBlock]` decodes instantly, SwiftUI views map 1:1

### Data flow

```
Feedbin API → HTML content → DataWriter (background):
  1. Parse HTML with XMLDocument(options: .documentTidyHTML)
  2. Walk DOM tree, produce [ArticleBlock]
  3. Encode to JSON, store in plainText field
  4. Keep bestHTML intact for reference

EntryDetailView (MainActor):
  1. Decode plainText as [ArticleBlock] (microseconds)
  2. ForEach block → render appropriate SwiftUI view
```

### Why not Option A or B?

- **Option A** works but puts HTML parsing on the display path. Even if fast (<1ms), it means the UI layer depends on libxml2 parsing, which is conceptually wrong for our architecture.
- **Option B** adds an unnecessary intermediate step (Markdown) when we could go directly to structured blocks.

### Why not keep Markdown as intermediate?

Markdown is lossy and requires re-parsing at display time. Structured blocks are:
- Lossless (we control the schema)
- Pre-parsed (zero work at display time)
- Type-safe (enum vs. string parsing)

## Implementation Impact

### Zero external dependencies

| Component | Technology |
|-----------|-----------|
| HTML parsing | `XMLDocument` (Foundation, macOS) |
| Inline formatting | SwiftUI `Text(markdown:)` / `AttributedString` |
| Block rendering | Custom SwiftUI views (~150 lines) |
| Storage | JSON-encoded `[ArticleBlock]` in `plainText` field |

### Files changed vs. previous plan

Same files, but no SPM dependencies to add:
- `DataWriter.swift` — add `parseHTMLToBlocks()` using XMLDocument
- `Entry.swift` — (no model changes, reuse `plainText`)
- `FeederApp.swift` — bump schema version
- `EntryDetailView.swift` — use new block renderer
- New: `ArticleBlock.swift` — block enum definition
- New: `ArticleBlockView.swift` — SwiftUI block renderer
- New: `HTMLToBlocks.swift` — XMLDocument DOM walker

### Classification compatibility

Classification uses `plainText` for LLM inference. If `plainText` now stores JSON blocks, we need to either:
1. Extract plain text from the blocks for classification (preferred — add a computed property)
2. Keep a separate `plainTextForClassification` field
3. Classify from `bestHTML` directly (already stored)

**Recommendation**: Add a computed `classificationText` property on `ArticleBlock` array that concatenates paragraph/heading text. Or simply keep `plainText` as plain text and add a new `articleBlocks` field for the structured data.

### Revised field strategy

| Field | Content | Used by |
|-------|---------|---------|
| `content` / `extractedContent` | Raw HTML | Reference, re-processing |
| `plainText` | Plain text (stripped) | Classification, search, fallback |
| `articleBlocks` | JSON `[ArticleBlock]` | **New** — display rendering |

This preserves backward compatibility: `plainText` stays as-is for classification, and `articleBlocks` is a new field for the rich rendering pipeline.

## Risks

| Risk | Mitigation |
|------|-----------|
| XMLDocument fails on malformed HTML | `documentTidyHTML` handles most cases; fallback to `plainText` display |
| JSON storage size | Typical article produces ~2–5KB JSON, negligible vs. raw HTML |
| New schema field | Bump schema version, auto-reset triggers fresh sync |
| Unknown HTML elements | Default to extracting text content, skip gracefully |
