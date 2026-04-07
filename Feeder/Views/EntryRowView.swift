import AppKit
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

  private var summaryText: String {
    let summary = entry.summaryPlainText
    return summary.isEmpty ? entry.plainText : summary
  }

  var body: some View {
    HStack(alignment: .top, spacing: 15) {
      // Favicon — own vertical column
      FaviconView(feed: entry.feed)
        .frame(width: 24, height: 24)
        .padding(.top, 2)

      // All text content aligned to the right of the icon
      VStack(alignment: .leading, spacing: 3) {
        // Feed name + time
        HStack(alignment: .top, spacing: 5) {
          Text(entry.title ?? "Untitled")
            .font(.system(size: FontTheme.rowTitleSize, weight: .regular))
            .lineLimit(2)
            .foregroundStyle(isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)
            .textRenderer(FakeBoldRenderer(isBold: !isRead))

          Spacer()

          Text(timeOnlyFormatter.string(from: entry.publishedAt))
            .font(.system(size: FontTheme.rowFeedNameSize))
            .foregroundStyle(.tertiary)
        }

        if let domain = entry.displayDomain, !domain.isEmpty {
          Text(domain.lowercased())
            .font(.system(size: FontTheme.rowFeedNameSize, weight: .regular))
            .foregroundStyle(FontTheme.domainPillColor)
        }

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
    Group {
      if let data = feed?.faviconData, let nsImage = NSImage(data: data) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 4))
      } else {
        initialsIcon
      }
    }
  }

  private var initialsIcon: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.secondary.opacity(0.2))
      Text(fallbackLetter)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.secondary)
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
  entry.summaryPlainText = "Coffee Stain is closing its mobile development arm in Malmö, Sweden."
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
  entry.summaryPlainText = "The European Union has approved comprehensive AI legislation."
  context.insert(entry)

  return EntryRowView(entry: entry)
    .modelContainer(container)
    .frame(width: 380)
    .padding()
}
