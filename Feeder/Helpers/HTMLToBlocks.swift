import Foundation

// MARK: - HTML to ArticleBlock conversion

private enum HTMLConstants {
    /// Tags whose content is entirely skipped.
    nonisolated static let skipTags: Set<String> = [
        "script", "style", "noscript", "nav", "footer", "header",
        "aside", "form", "iframe", "svg", "video", "audio", "button", "input",
    ]

    /// Tags that are transparent containers — recurse into children.
    nonisolated static let containerTags: Set<String> = [
        "div", "section", "article", "span", "main", "figure", "figcaption",
        "dl", "dd", "dt", "details", "summary", "center",
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
    // documentTidyHTML wraps content in <html><body>…</body></html>
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

    // Skip blacklisted tags entirely
    if HTMLConstants.skipTags.contains(tag) { return }

    switch tag {
    case "p":
        let text = extractInlineMarkdown(from: element)
        if !text.isEmpty {
            blocks.append(.paragraph(text: text))
        }

    case "h1", "h2", "h3", "h4", "h5", "h6":
        let level = Int(String(tag.last!)) ?? 2
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
        let text = extractInlineMarkdown(from: element)
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
        break // handled within inline extraction

    case "a":
        // Top-level link wrapping an image or text
        let text = extractInlineMarkdown(from: element)
        if !text.isEmpty {
            blocks.append(.paragraph(text: text))
        }

    default:
        if HTMLConstants.containerTags.contains(tag) {
            walkChildren(of: element, into: &blocks)
        } else {
            // Unknown tag — extract text if any
            let text = extractInlineMarkdown(from: element)
            if !text.isEmpty {
                blocks.append(.paragraph(text: text))
            }
        }
    }
}

// MARK: - Inline Markdown extraction

/// Recursively extracts text from an element, converting inline HTML tags
/// to Markdown syntax (bold, italic, links, inline code).
nonisolated private func extractInlineMarkdown(from element: XMLElement) -> String {
    var result = ""
    for child in element.children ?? [] {
        if child.kind == .text {
            result += child.stringValue ?? ""
        } else if let el = child as? XMLElement {
            guard let tag = el.name?.lowercased() else { continue }

            if HTMLConstants.skipTags.contains(tag) { continue }

            switch tag {
            case "strong", "b":
                let inner = extractInlineMarkdown(from: el)
                if !inner.isEmpty { result += "**\(inner)**" }
            case "em", "i":
                let inner = extractInlineMarkdown(from: el)
                if !inner.isEmpty { result += "*\(inner)*" }
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
            case "span":
                result += extractInlineMarkdown(from: el)
            default:
                result += extractInlineMarkdown(from: el)
            }
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
