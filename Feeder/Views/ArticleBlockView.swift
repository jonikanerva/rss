import SwiftUI

/// Renders an array of ArticleBlocks as styled SwiftUI views.
struct ArticleBlockView: View {
  let blocks: [ArticleBlock]
  @Environment(AppFontSettings.self)
  private var fontSettings

  /// Cached Markdown→AttributedString parses, keyed by the raw Markdown string.
  /// Avoids re-parsing on every re-render of this view for the reader pane.
  @State
  private var attributedCache: [String: AttributedString] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        renderBlock(block)
      }
    }
    .onAppear { rebuildCache() }
    .onChange(of: blocks) { rebuildCache() }
  }

  private func rebuildCache() {
    var cache: [String: AttributedString] = [:]
    let include: (String) -> Void = { text in
      if cache[text] == nil {
        cache[text] = (try? AttributedString(markdown: text)) ?? AttributedString(text)
      }
    }
    for block in blocks {
      switch block {
      case .paragraph(let text), .heading(_, let text), .blockquote(let text):
        include(text)
      case .list(_, let items):
        for item in items { include(item) }
      case .image, .codeBlock, .divider:
        continue
      }
    }
    attributedCache = cache
  }

  @ViewBuilder
  private func renderBlock(_ block: ArticleBlock) -> some View {
    switch block {
    case .paragraph(let text):
      Text(attributedInline(text))
        .font(fontSettings.body)
        .lineSpacing(6)

    case .heading(let level, let text):
      Text(attributedInline(text))
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 8 : 4)

    case .image(let url, let alt):
      articleImage(url: url, alt: alt)

    case .codeBlock(let code):
      Text(code.trimmingCharacters(in: .whitespacesAndNewlines))
        .font(fontSettings.codeBlock)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

    case .list(let ordered, let items):
      articleList(ordered: ordered, items: items)

    case .blockquote(let text):
      Text(attributedInline(text))
        .font(fontSettings.body)
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

  /// Maps HTML heading level (1–6) to a text-size-aware semantic font.
  /// `level` outside 1–4 falls back to `fontSettings.minorInlineHeading` — a
  /// reader-pane alias kept distinct from `fontSettings.headline` (sheet
  /// titles) and `fontSettings.rowTitle` (article-list rows) so a future
  /// reader redesign can retune h5/h6 without rippling into other surfaces.
  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: fontSettings.articleTitle
    case 2: fontSettings.sectionHeader
    case 3: fontSettings.subsectionHeader
    case 4: fontSettings.minorHeader
    default: fontSettings.minorInlineHeading
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
              .font(fontSettings.body)
              .foregroundStyle(.secondary)
              .frame(minWidth: 20, alignment: .trailing)
          } else {
            Text("•")
              .font(fontSettings.body)
              .foregroundStyle(.secondary)
          }
          Text(attributedInline(item))
            .font(fontSettings.body)
            .lineSpacing(4)
        }
      }
    }
    .padding(.leading, 4)
  }

  // MARK: - Inline Markdown → AttributedString

  private func attributedInline(_ markdown: String) -> AttributedString {
    if let cached = attributedCache[markdown] { return cached }
    return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
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
  .environment(AppFontSettings())
  .frame(width: 700, height: 600)
}
