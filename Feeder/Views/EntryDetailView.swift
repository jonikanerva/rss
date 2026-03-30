import SwiftData
import SwiftUI

struct EntryDetailView: View {
  let entry: Entry

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(entry.title ?? "Untitled")
          .font(.system(size: FontTheme.articleTitleSize, weight: .bold))
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          if !entry.displayDomain.isEmpty {
            Text(entry.displayDomain)
              .font(.system(size: FontTheme.pillSize, weight: .medium))
              .foregroundStyle(Color(hex: 0xE8654A))
          }

          if let feedTitle = entry.feed?.title {
            Text(feedTitle)
              .font(.system(size: FontTheme.metadataSize))
              .foregroundStyle(.secondary)
          }

          if let author = entry.author, !author.isEmpty {
            Text(author)
              .font(.system(size: FontTheme.metadataSize))
              .foregroundStyle(.secondary)
          }

          Text(entry.publishedAt, format: .dateTime.month(.wide).day().year().hour().minute())
            .font(.system(size: FontTheme.metadataSize))
            .foregroundStyle(.tertiary)
        }

        Divider()

        // Article body — structured blocks from database
        ArticleBlockView(blocks: entry.parsedBlocks)
          .textSelection(.enabled)
      }
      .frame(maxWidth: 660, alignment: .leading)
      .padding(.horizontal, 50)
      .padding(.top, 24)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .id(entry.feedbinEntryID)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Article: \(entry.title ?? "Untitled")")
    .accessibilityIdentifier("entry.detail")
  }
}

// MARK: - Preview

#Preview("Article Detail with Sources") {
  articleDetailPreview()
}

@MainActor
private func articleDetailPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard let container = try? ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config) else {
    fatalError("Preview ModelContainer failed")
  }
  let context = container.mainContext

  let feed = Feed(
    feedbinSubscriptionID: 1, feedbinFeedID: 1,
    title: "The Verge", feedURL: "https://theverge.com/rss",
    siteURL: "https://theverge.com", createdAt: .now
  )
  context.insert(feed)

  let entry = Entry(
    feedbinEntryID: 1, title: "Apple unveils M5 Ultra chip with record-breaking AI performance",
    author: "Tom Warren", url: "https://example.com/1",
    content: "<p>Apple today announced the M5 Ultra, its most powerful chip ever.</p>",
    summary: nil, extractedContentURL: nil,
    publishedAt: .now.addingTimeInterval(-3600), createdAt: .now
  )
  entry.feed = feed
  entry.displayDomain = "theverge.com"
  context.insert(entry)

  return EntryDetailView(entry: entry)
    .modelContainer(container)
    .frame(width: 600, height: 500)
}
