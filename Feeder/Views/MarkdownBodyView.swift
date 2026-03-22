import SwiftUI
import Markdown

// MARK: - MarkdownBodyView

/// Renders a Markdown string as a sequence of styled SwiftUI blocks.
/// Parses Markdown into an AST using apple/swift-markdown and emits
/// native SwiftUI views for each block type (paragraphs, headings,
/// images, lists, code blocks, blockquotes, thematic breaks).
struct MarkdownBodyView: View {
    let markdown: String

    var body: some View {
        let document = Document(parsing: markdown)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func renderBlock(_ markup: any Markup) -> some View {
        switch markup {
        case let heading as Heading:
            renderHeading(heading)
        case let paragraph as Paragraph:
            renderParagraph(paragraph)
        case let codeBlock as CodeBlock:
            renderCodeBlock(codeBlock)
        case let list as UnorderedList:
            renderUnorderedList(list)
        case let list as OrderedList:
            renderOrderedList(list)
        case let quote as BlockQuote:
            renderBlockQuote(quote)
        case is ThematicBreak:
            Divider()
                .padding(.vertical, 4)
        case let htmlBlock as HTMLBlock:
            renderHTMLBlock(htmlBlock)
        case let image as Markdown.Image:
            renderImage(image)
        default:
            Text(markup.format())
                .font(.system(size: FontTheme.bodySize))
        }
    }

    // MARK: - Headings

    private func renderHeading(_ heading: Heading) -> some View {
        let fontSize: CGFloat = switch heading.level {
        case 1: FontTheme.articleTitleSize
        case 2: FontTheme.sectionHeaderSize
        case 3: FontTheme.rowTitleSize
        default: FontTheme.bodySize
        }
        return Text(inlineMarkdown(heading))
            .font(.system(size: fontSize, weight: .bold))
            .padding(.top, heading.level <= 2 ? 8 : 4)
    }

    // MARK: - Paragraphs

    private func renderParagraph(_ paragraph: Paragraph) -> some View {
        // Check if paragraph contains only an image
        if paragraph.childCount == 1, let image = paragraph.child(at: 0) as? Markdown.Image {
            return AnyView(renderImage(image))
        }
        return AnyView(
            Text(inlineMarkdown(paragraph))
                .font(.system(size: FontTheme.bodySize))
                .lineSpacing(6)
        )
    }

    // MARK: - Images

    private func renderImage(_ image: Markdown.Image) -> some View {
        let urlString = image.source ?? ""
        return Group {
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 620)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    case .failure:
                        EmptyView()
                    case .empty:
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(height: 200)
                            .overlay {
                                ProgressView()
                            }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - Code blocks

    private func renderCodeBlock(_ codeBlock: CodeBlock) -> some View {
        Text(codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: FontTheme.bodySize - 2, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Unordered lists

    private func renderUnorderedList(_ list: UnorderedList) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.listItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .font(.system(size: FontTheme.bodySize))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            renderBlock(child)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Ordered lists

    private func renderOrderedList(_ list: OrderedList) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.listItems.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: FontTheme.bodySize))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            renderBlock(child)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Block quotes

    private func renderBlockQuote(_ quote: BlockQuote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(quote.children.enumerated()), id: \.offset) { _, child in
                renderBlock(child)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 3)
        }
    }

    // MARK: - HTML blocks (fallback)

    private func renderHTMLBlock(_ block: HTMLBlock) -> some View {
        let stripped = stripHTMLToPlainText(block.rawHTML)
        return Group {
            if !stripped.isEmpty {
                Text(stripped)
                    .font(.system(size: FontTheme.bodySize))
                    .lineSpacing(6)
            }
        }
    }

    // MARK: - Inline markdown extraction

    /// Extracts the inline content of a block as a Markdown string and
    /// returns it as an AttributedString for SwiftUI Text rendering.
    private func inlineMarkdown(_ block: any Markup) -> AttributedString {
        let source = block.children.map { child in
            child.format()
        }.joined()
        do {
            return try AttributedString(markdown: source)
        } catch {
            return AttributedString(source)
        }
    }
}
