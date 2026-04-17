import SwiftData
import SwiftUI

// MARK: - Shared Detail Date Formatting

/// Shared date formatters for article detail views (both SwiftUI and WebView).
enum DetailDateFormatting {
  static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEE d. MMMM yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH.mm"
    return f
  }()

  static func formatDate(_ date: Date) -> String {
    let dateStr = dateFormatter.string(from: date)
    let timeStr = timeFormatter.string(from: date)
    return "\(dateStr) at \(timeStr)"
  }
}

struct EntryDetailView: View {
  let entry: Entry
  let viewMode: ArticleViewMode
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    Group {
      switch viewMode {
      case .web:
        ArticleWebView(entry: entry)
      case .reader:
        readerView
      }
    }
    // No .id(entry.feedbinEntryID) — let SwiftUI diff bindings instead of tearing
    // down the WKWebView. ArticleWebView.updateNSView already guards against
    // duplicate loads via the coordinator's currentEntryID.
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: viewMode)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Article: \(entry.title ?? "Untitled")")
    .accessibilityIdentifier("entry.detail")
  }

  private var readerView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        articleHeader

        Divider()

        // Article body — structured blocks from database
        ArticleBlockView(blocks: entry.parsedBlocks)
          .textSelection(.enabled)
      }
      .frame(maxWidth: 610, alignment: .leading)
      .padding(.horizontal, 50)
      .padding(.top, 24)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var articleHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Date + time
      Text(DetailDateFormatting.formatDate(entry.publishedAt))
        .font(.system(size: FontTheme.captionSize, weight: .medium))
        .foregroundStyle(.secondary)

      // Title
      Text(entry.title ?? "Untitled")
        .font(.system(size: FontTheme.articleTitleSize, weight: .bold))
        .fixedSize(horizontal: false, vertical: true)

      // Favicon + author/domain
      HStack(alignment: .center, spacing: 8) {
        FaviconView(feed: entry.feed)
          .frame(width: 20, height: 20)

        VStack(alignment: .leading, spacing: 2) {
          if let author = entry.author, !author.isEmpty {
            Text(author)
              .font(.system(size: FontTheme.captionSize, weight: .medium))
              .foregroundStyle(.secondary)
          }
          if let domain = entry.displayDomain, !domain.isEmpty {
            Text(domain.lowercased())
              .font(.system(size: FontTheme.captionSize, weight: .medium))
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
  }
}

// MARK: - Article View Mode

enum ArticleViewMode {
  case web
  case reader
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

  return EntryDetailView(entry: entry, viewMode: .reader)
    .modelContainer(container)
    .frame(width: 600, height: 500)
}
