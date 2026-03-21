# Research: Article Reader — Markdown Rendering Strategy

Date: 2026-03-21
Status: Complete
Decision: Pending user approval

## Problem

`EntryDetailView` displays `entry.plainText` — a pre-stripped string that loses all formatting: paragraphs, bold/italic, images, links, lists, and shows raw HTML entities (e.g., `&#x200C;`). Articles need to render close to original formatting while maintaining the app's calm visual style.

## Current Architecture

| Field | Type | Source |
|-------|------|--------|
| `content` | `String?` | Feed HTML |
| `summary` | `String?` | Feed summary |
| `extractedContent` | `String?` | Feedbin Mercury Parser (full article HTML) |
| `bestHTML` | computed | `extractedContent > content > summary` |
| `plainText` | `String` | Pre-stripped at persist time, used for display |

Key constraint: `DataWriter` is a `@ModelActor` (background actor). Any conversion library must work off-MainActor.

## Decision: HTML → Markdown Conversion

The top-level decision is to convert HTML to Markdown at persist time (same pattern as `plainText`), storing it as a new `markdownBody` field on `Entry`.

### Library Options

#### 1. Demark (steipete/Demark)
- **Engine**: Turndown.js via WKWebView, or html-to-md via JavaScriptCore
- **Quality**: Excellent — full Turndown.js is the gold standard for HTML→MD
- **Performance**: First call ~100ms (setup), subsequent 10–50ms
- **Problem**: WKWebView engine requires `@MainActor`. JavaScriptCore engine may work on background threads but still has JS overhead and uncertain actor-safety
- **Dependencies**: None (bundles JS)
- **Verdict**: ⚠️ Actor isolation conflict with DataWriter. Would need MainActor trampoline or separate conversion pipeline

#### 2. SwiftHTMLToMarkdown (ActuallyTaylor/SwiftHTMLToMarkdown)
- **Engine**: Pure Swift, uses SwiftSoup for HTML parsing
- **Quality**: Good for common elements (paragraphs, headings, bold/italic, links, images, lists, code blocks)
- **Performance**: Fast (native Swift, no JS overhead)
- **Problem**: Smaller community (22 commits, 3 releases), some edge cases may not be covered
- **Dependencies**: SwiftSoup (well-established HTML parser)
- **Verdict**: ✅ Pure Swift, works on any actor, good enough for RSS content

#### 3. Custom implementation (regex/XMLParser)
- **Verdict**: ❌ Too brittle for real-world HTML. Not recommended.

### Recommendation: SwiftHTMLToMarkdown

Best fit for our architecture:
- Pure Swift → works in `DataWriter` (`@ModelActor`) without actor isolation issues
- SwiftSoup dependency is well-maintained and robust
- RSS article HTML is relatively predictable (not arbitrary web pages)
- Pre-computed at persist time → zero rendering-time cost

## Decision: Markdown Rendering in SwiftUI

### Option A: Native `Text(markdown:)` only

```swift
Text(entry.markdownBody)  // SwiftUI handles inline markdown
```

**Supports**: bold, italic, strikethrough, inline code, links (clickable)
**Does NOT support**: images, tables, code blocks (as block elements), headings (as styled blocks), blockquotes, lists (as formatted blocks)
**Performance**: Instant (AttributedString parsing)
**Code complexity**: Minimal — single line change
**Visual quality**: Good for text-heavy articles, but inline-only rendering flattens structure

### Option B: MarkdownUI / Textual (third-party renderer)

**MarkdownUI** (gonzalezreal/swift-markdown-ui):
- Full block rendering: headings, images, tables, code blocks, lists, blockquotes
- Theming with built-in themes (GitHub, DocC) and custom themes
- ⚠️ **Maintenance mode** — no new development
- ⚠️ **Known performance issue** with long content (GitHub issue #426 — freezes on moderate-length articles)

**Textual** (gonzalezreal/textual):
- Spiritual successor to MarkdownUI, redesigned rendering pipeline
- Preserves SwiftUI's native Text rendering → better performance
- Full theming via `StructuredText.Style` protocol
- ⚠️ **v0.1.0** — very early, API may change
- ⚠️ Unclear image/table support maturity at this stage

### Option C: apple/swift-markdown AST + custom SwiftUI renderer

Parse markdown to AST with Apple's `swift-markdown`, walk the tree, emit SwiftUI views per block type.

```
Markdown string → swift-markdown AST → MarkdownWalker → VStack of SwiftUI views
```

| Block type | SwiftUI view |
|-----------|-------------|
| Paragraph | `Text(markdown:)` — inline formatting handled natively |
| Heading | `Text()` with scaled font |
| Image | `AsyncImage(url:)` |
| Code block | `Text()` + monospace + background |
| List | `VStack` + bullet/number prefix |
| Blockquote | `Text()` + leading border |
| Table | `Grid` |
| Thematic break | `Divider()` |

**Performance**: Instant (AST parse is fast, view construction is standard SwiftUI)
**Code complexity**: ~150–250 lines for the walker + view builder
**Visual quality**: Full control over every element's appearance
**Dependencies**: `swift-markdown` (Apple's own, well-maintained, pure Swift)

## Comparison Matrix

| Criterion | A: Text(markdown:) | B: Textual | C: AST + custom |
|-----------|:------------------:|:----------:|:----------------:|
| Code complexity | ★★★ trivial | ★★ add dependency | ★★ ~200 lines |
| Image support | ❌ | ✅ (if mature) | ✅ |
| Table support | ❌ | ✅ (if mature) | ✅ |
| Heading styling | ❌ | ✅ | ✅ |
| Link support | ✅ | ✅ | ✅ |
| Bold/italic | ✅ | ✅ | ✅ |
| Lists | ❌ (no bullets) | ✅ | ✅ |
| Performance | ★★★ instant | ★★ good (claimed) | ★★★ instant |
| Stability risk | ★★★ Apple API | ★ v0.1.0 | ★★★ Apple lib |
| Style control | ★ limited | ★★★ full theming | ★★★ full control |
| Dependencies | none | textual + swift-markdown | swift-markdown |

## Recommendation

**Option C** (apple/swift-markdown AST + custom renderer) is the best fit:

1. **Full control** over visual style → "calm reading experience" goal
2. **Apple's own library** — stable, well-maintained, no third-party risk
3. **Instant performance** — AST parsing is fast, views are standard SwiftUI
4. **~200 lines of code** — manageable, no magic, easy to debug and extend
5. **No early-stage dependency risk** (Textual v0.1.0 is too young)

However, **Option A is viable as a quick first step**: swap `plainText` for `markdownBody` with `Text(markdown:)` to immediately get bold/italic/links. Then layer on the AST renderer for images/headings/lists.

## Implementation Sketch

### Data layer changes
1. Add `markdownBody: String` field to `Entry` model
2. Add SwiftHTMLToMarkdown SPM dependency
3. In `DataWriter.persistEntries()`: compute `markdownBody` alongside `plainText`
4. In `DataWriter.applyExtractedContent()`: recompute `markdownBody` when extracted content arrives
5. Bump schema version in `FeederApp.swift`

### UI layer changes (phased)
**Phase 1** — Quick win: Replace `Text(current.plainText)` with `Text(current.markdownBody)` in `EntryDetailView`
**Phase 2** — Full renderer: Add `swift-markdown` dependency, build `MarkdownBodyView` that walks AST and emits SwiftUI views

### New dependencies
- `SwiftHTMLToMarkdown` — HTML→Markdown conversion (pure Swift, uses SwiftSoup)
- `swift-markdown` — Apple's Markdown parser (Phase 2 only)
