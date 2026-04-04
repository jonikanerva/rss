import Foundation
import OSLog

// MARK: - HTML to ArticleBlock conversion

private enum HTMLConstants {
  nonisolated static let logger = Logger(subsystem: "com.feeder.app", category: "HTMLToBlocks")

  /// Tags that are known-safe to skip silently (no content loss).
  nonisolated static let knownSkipTags: Set<String> = [
    "script", "style", "noscript", "nav", "footer", "header",
    "aside", "form", "iframe", "svg", "video", "audio", "button",
    "input", "select", "textarea", "label", "fieldset", "legend",
    "meta", "link", "head", "title", "colgroup", "col", "caption",
    "table", "thead", "tbody", "tfoot", "tr", "td", "th",
  ]

  /// Tags that are transparent containers — recurse into children at block level.
  nonisolated static let containerTags: Set<String> = [
    "div", "section", "article", "main", "figure", "figcaption",
    "dl", "dd", "dt", "details", "summary", "center",
  ]

  /// Inline formatting tags — handled inside extractInlineMarkdown,
  /// and also treated as implicit paragraphs when they appear at block level.
  nonisolated static let inlineTags: Set<String> = [
    "strong", "b", "em", "i", "a", "code", "br", "img", "span",
    "sub", "sup", "mark", "del", "s", "small", "abbr", "time",
    "cite", "q", "dfn", "var", "samp", "kbd", "wbr", "u",
    "strike", "ins", "address",
  ]
}

/// Convert an HTML string into structured article blocks.
/// Uses Foundation XMLDocument with documentTidyHTML for robust parsing.
/// Falls back to a single paragraph with stripped text on parse error.
nonisolated func parseHTMLToBlocks(_ html: String) -> [ArticleBlock] {
  guard !html.isEmpty else { return [] }
  do {
    let doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
    guard let body = findBody(in: doc) else {
      return fallbackBlocks(html)
    }
    var blocks: [ArticleBlock] = []
    walkChildren(of: body, into: &blocks)
    return blocks.isEmpty ? fallbackBlocks(html) : blocks
  } catch {
    return fallbackBlocks(html)
  }
}

// MARK: - DOM walking

nonisolated private func findBody(in doc: XMLDocument) -> XMLElement? {
  if let body = try? doc.nodes(forXPath: "//body").first as? XMLElement {
    return body
  }
  return doc.rootElement()
}

nonisolated private func walkChildren(of element: XMLElement, into blocks: inout [ArticleBlock]) {
  for child in element.children ?? [] {
    if let el = child as? XMLElement {
      processElement(el, into: &blocks)
    } else if child.kind == .text {
      let trimmed = (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        blocks.append(.paragraph(text: trimmed))
      }
    }
  }
}

nonisolated private func processElement(_ element: XMLElement, into blocks: inout [ArticleBlock]) {
  guard let tag = element.name?.lowercased() else { return }

  switch tag {
  // Block content tags
  case "p":
    let text = extractInlineMarkdown(from: element)
    if !text.isEmpty {
      blocks.append(.paragraph(text: text))
    }

  case "h1", "h2", "h3", "h4", "h5", "h6":
    let level = tag.last.flatMap { Int(String($0)) } ?? 2
    let text = extractInlineMarkdown(from: element)
    if !text.isEmpty {
      blocks.append(.heading(level: level, text: text))
    }

  case "img":
    if let src = element.attribute(forName: "src")?.stringValue, !src.isEmpty {
      let alt = element.attribute(forName: "alt")?.stringValue ?? ""
      blocks.append(.image(url: src, alt: alt))
    }

  case "ul":
    let items = extractListItems(from: element)
    if !items.isEmpty {
      blocks.append(.list(ordered: false, items: items))
    }

  case "ol":
    let items = extractListItems(from: element)
    if !items.isEmpty {
      blocks.append(.list(ordered: true, items: items))
    }

  case "blockquote":
    // Blockquote may contain <p> children — walk them as sub-blocks
    // and join their text with newlines for a single blockquote.
    var subBlocks: [ArticleBlock] = []
    walkChildren(of: element, into: &subBlocks)
    let text = subBlocks.compactMap { block in
      switch block {
      case .paragraph(let t), .heading(_, let t), .blockquote(let t):
        return t
      case .list(_, let items):
        return items.joined(separator: "\n")
      default:
        return nil
      }
    }.joined(separator: "\n\n")
    if !text.isEmpty {
      blocks.append(.blockquote(text: text))
    }

  case "pre":
    let code = element.stringValue ?? ""
    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      blocks.append(.codeBlock(code: code))
    }

  case "hr":
    blocks.append(.divider)

  case "br":
    break

  default:
    // Containers — recurse into children
    if HTMLConstants.containerTags.contains(tag) {
      walkChildren(of: element, into: &blocks)
      return
    }

    // Inline tags at block level (e.g. <strong>text</strong> without <p> wrapper)
    // — treat as an implicit paragraph
    if HTMLConstants.inlineTags.contains(tag) {
      let text = extractInlineMarkdown(from: element)
      if !text.isEmpty {
        blocks.append(.paragraph(text: text))
      }
      return
    }

    // Known skip tags — silently ignore
    if HTMLConstants.knownSkipTags.contains(tag) {
      return
    }

    // Unknown tag — skip and log for debugging
    HTMLConstants.logger.debug("Skipping unknown HTML tag: <\(tag)>")
  }
}

// MARK: - Inline Markdown extraction

/// Recursively extracts text from an element, converting inline HTML tags
/// to Markdown syntax (bold, italic, links, inline code).
/// Block-level tags encountered inline (e.g. <p> inside <blockquote>)
/// are recursed into transparently.
nonisolated private func extractInlineMarkdown(from element: XMLElement) -> String {
  var result = ""
  for child in element.children ?? [] {
    if child.kind == .text {
      result += child.stringValue ?? ""
    } else if let el = child as? XMLElement {
      guard let tag = el.name?.lowercased() else { continue }

      switch tag {
      case "strong", "b":
        let inner = extractInlineMarkdown(from: el)
        if !inner.isEmpty { result += "**\(inner)**" }
      case "em", "i":
        let inner = extractInlineMarkdown(from: el)
        if !inner.isEmpty { result += "*\(inner)*" }
      case "strike", "s", "del":
        let inner = extractInlineMarkdown(from: el)
        if !inner.isEmpty { result += "~~\(inner)~~" }
      case "ins", "u":
        // No standard Markdown for underline — render as plain text
        result += extractInlineMarkdown(from: el)
      case "a":
        let inner = extractInlineMarkdown(from: el)
        let href = el.attribute(forName: "href")?.stringValue ?? ""
        if !inner.isEmpty, !href.isEmpty {
          result += "[\(inner)](\(href))"
        } else {
          result += inner
        }
      case "code":
        let inner = el.stringValue ?? ""
        if !inner.isEmpty { result += "`\(inner)`" }
      case "br":
        result += "\n"
      case "img":
        if let src = el.attribute(forName: "src")?.stringValue, !src.isEmpty {
          let alt = el.attribute(forName: "alt")?.stringValue ?? ""
          result += "![\(alt)](\(src))"
        }
      default:
        // Block tags appearing inline (e.g. <p> inside <li>, <ul> inside <blockquote>)
        // and other inline/container tags — recurse transparently
        if HTMLConstants.inlineTags.contains(tag)
          || HTMLConstants.containerTags.contains(tag)
          || isBlockContentTag(tag)
        {
          result += extractInlineMarkdown(from: el)
        } else if !HTMLConstants.knownSkipTags.contains(tag) {
          HTMLConstants.logger.debug("Skipping unknown inline tag: <\(tag)>")
        }
      }
    }
  }
  return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Block content tags that may appear nested inside inline contexts.
nonisolated private func isBlockContentTag(_ tag: String) -> Bool {
  switch tag {
  case "p", "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "li", "blockquote", "pre":
    return true
  default:
    return false
  }
}

// MARK: - List extraction

nonisolated private func extractListItems(from listElement: XMLElement) -> [String] {
  (listElement.children ?? []).compactMap { child in
    guard let li = child as? XMLElement, li.name?.lowercased() == "li" else { return nil }
    let text = extractInlineMarkdown(from: li)
    return text.isEmpty ? nil : text
  }
}

// MARK: - Fallback

nonisolated private func fallbackBlocks(_ html: String) -> [ArticleBlock] {
  let text = stripHTMLToPlainText(html)
  guard !text.isEmpty else { return [] }
  return [.paragraph(text: text)]
}

// MARK: - HTML Escaping

extension String {
  /// Escape characters that are special in HTML to prevent injection.
  nonisolated var htmlEscaped: String {
    self
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
