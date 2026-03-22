import SwiftUI

/// Renders an array of ArticleBlocks as styled SwiftUI views.
struct ArticleBlockView: View {
    let blocks: [ArticleBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: ArticleBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(attributedInline(text))
                .font(.system(size: FontTheme.bodySize))
                .lineSpacing(6)

        case .heading(let level, let text):
            Text(attributedInline(text))
                .font(.system(size: headingSize(level), weight: .bold))
                .padding(.top, level <= 2 ? 8 : 4)

        case .image(let url, let alt):
            articleImage(url: url, alt: alt)

        case .codeBlock(let code):
            Text(code.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: FontTheme.bodySize - 2, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

        case .list(let ordered, let items):
            articleList(ordered: ordered, items: items)

        case .blockquote(let text):
            Text(attributedInline(text))
                .font(.system(size: FontTheme.bodySize))
                .lineSpacing(6)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 3)
                }

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Headings

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: FontTheme.articleTitleSize
        case 2: FontTheme.sectionHeaderSize
        case 3: FontTheme.rowTitleSize
        default: FontTheme.bodySize
        }
    }

    // MARK: - Images

    private static let allowedImageSchemes: Set<String> = ["https", "http"]

    private func articleImage(url: String, alt: String) -> some View {
        Group {
            if let imageURL = URL(string: url),
                let scheme = imageURL.scheme?.lowercased(),
                Self.allowedImageSchemes.contains(scheme)
            {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 620)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    case .failure:
                        EmptyView()
                    case .empty:
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(height: 200)
                            .frame(maxWidth: 620)
                            .overlay { ProgressView() }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - Lists

    private func articleList(ordered: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if ordered {
                        Text("\(index + 1).")
                            .font(.system(size: FontTheme.bodySize))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                    } else {
                        Text("•")
                            .font(.system(size: FontTheme.bodySize))
                            .foregroundStyle(.secondary)
                    }
                    Text(attributedInline(item))
                        .font(.system(size: FontTheme.bodySize))
                        .lineSpacing(4)
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Inline Markdown → AttributedString

    private func attributedInline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

// MARK: - Preview

#Preview("Article Blocks") {
    ScrollView {
        ArticleBlockView(blocks: [
            .heading(level: 1, text: "Sample Article Title"),
            .paragraph(text: "This is a paragraph with **bold**, *italic*, and a [link](https://example.com)."),
            .image(url: "https://picsum.photos/600/300", alt: "Sample image"),
            .heading(level: 2, text: "A Subheading"),
            .paragraph(text: "Another paragraph with `inline code` and some regular text."),
            .list(ordered: false, items: ["First item", "Second item with **bold**", "Third item"]),
            .blockquote(text: "This is a blockquote with *emphasis*."),
            .codeBlock(code: "let x = 42\nprint(x)"),
            .divider,
            .list(ordered: true, items: ["Step one", "Step two", "Step three"]),
        ])
        .padding(32)
        .frame(maxWidth: 660, alignment: .leading)
    }
    .frame(width: 700, height: 600)
}
