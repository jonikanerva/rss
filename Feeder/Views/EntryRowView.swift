import SwiftData
import SwiftUI

// MARK: - Time Formatter

private let timeOnlyFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "HH.mm"
  return f
}()

// MARK: - Entry Row View

struct EntryRowView: View {
  let entry: Entry
  @Environment(\.pendingReadIDs)
  private var pendingReadIDs

  private var isRead: Bool { entry.isRead || pendingReadIDs.contains(entry.feedbinEntryID) }

  private var feedName: String {
    entry.feed?.title ?? entry.displayDomain ?? ""
  }

  private var summaryText: String {
    if let summary = entry.summary, !summary.isEmpty {
      return stripHTMLToPlainText(summary)
    }
    return entry.plainText
  }

  var body: some View {
    #if DEBUG
      let _ = Self._printChanges()
    #endif
    HStack(alignment: .top, spacing: 15) {
      // Favicon — own vertical column
      FaviconView(feed: entry.feed)
        .frame(width: 24, height: 24)
        .padding(.top, 2)

      // All text content aligned to the right of the icon
      VStack(alignment: .leading, spacing: 3) {
        // Feed name + time
        HStack(spacing: 6) {
          Text(feedName.uppercased())
            .font(.system(size: FontTheme.rowFeedNameSize, weight: .semibold))
            .foregroundStyle(FontTheme.domainPillColor)
            .lineLimit(1)

          Spacer()

          Text(timeOnlyFormatter.string(from: entry.publishedAt))
            .font(.system(size: FontTheme.rowFeedNameSize))
            .foregroundStyle(.tertiary)
        }

        // Title
        Text(entry.title ?? "Untitled")
          .font(.system(size: FontTheme.rowTitleSize, weight: isRead ? .regular : .semibold))
          .lineLimit(2)
          .foregroundStyle(isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)

        // Summary excerpt
        if !summaryText.isEmpty {
          Text(summaryText)
            .font(.system(size: FontTheme.rowSummarySize))
            .lineLimit(2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isRead ? (entry.title ?? "Untitled") : "Unread, \(entry.title ?? "Untitled")")
    .accessibilityIdentifier("entry.row.\(entry.feedbinEntryID)")
  }
}

// MARK: - Favicon View

struct FaviconView: View {
  let feed: Feed?

  private var fallbackLetter: String {
    guard let title = feed?.title, let first = title.first else { return "?" }
    return String(first).uppercased()
  }

  var body: some View {
    if let faviconURL = feed?.faviconURL, let url = URL(string: faviconURL) {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let image):
          image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        default:
          initialsIcon
        }
      }
    } else {
      initialsIcon
    }
  }

  private var initialsIcon: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4)
        .fill(FontTheme.domainPillColor.opacity(0.15))
      Text(fallbackLetter)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(FontTheme.domainPillColor)
    }
  }
}

// MARK: - Preview

#Preview("Unread Entry") {
  unreadEntryRowPreview()
}

#Preview("Read Entry") {
  readEntryRowPreview()
}

@MainActor
private func unreadEntryRowPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard let container = try? ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config) else {
    fatalError("Preview ModelContainer failed")
  }
  let context = container.mainContext

  let feed = Feed(
    feedbinSubscriptionID: 1, feedbinFeedID: 1,
    title: "Mobilegamer.biz", feedURL: "https://mobilegamer.biz/feed",
    siteURL: "https://mobilegamer.biz", createdAt: .now
  )
  context.insert(feed)

  let entry = Entry(
    feedbinEntryID: 1, title: "Goat Simulator maker Coffee Stain to close its mobile studio",
    author: "Neil Long", url: "https://example.com/1",
    content: "<p>Coffee Stain is closing its mobile development arm...</p>",
    summary: "Coffee Stain is closing its mobile development arm in Malmö, Sweden.",
    extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-3600), createdAt: .now
  )
  entry.feed = feed
  entry.isRead = false
  entry.formattedDate = "Today, 15th Mar, 09:30"
  entry.displayDomain = "mobilegamer.biz"
  entry.plainText = "Coffee Stain is closing its mobile development arm in Malmö, Sweden."
  context.insert(entry)

  return EntryRowView(entry: entry)
    .modelContainer(container)
    .frame(width: 380)
    .padding()
}

@MainActor
private func readEntryRowPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard let container = try? ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config) else {
    fatalError("Preview ModelContainer failed")
  }
  let context = container.mainContext

  let entry = Entry(
    feedbinEntryID: 2, title: "EU passes sweeping AI regulation requiring model transparency",
    author: nil, url: "https://example.com/2",
    content: nil,
    summary: "The European Union has approved comprehensive AI legislation.",
    extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-90000), createdAt: .now
  )
  entry.isRead = true
  entry.formattedDate = "Yesterday, 14th Mar, 08:30"
  entry.displayDomain = "arstechnica.com"
  entry.plainText = "The European Union has approved comprehensive AI legislation."
  context.insert(entry)

  return EntryRowView(entry: entry)
    .modelContainer(container)
    .frame(width: 380)
    .padding()
}
