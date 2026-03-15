import SwiftUI
import SwiftData

// MARK: - Source pill colors

private let activePillColor = Color(hex: 0xE8866A)
private let inactivePillColor = Color(hex: 0x3A3A3C)

struct EntryDetailView: View {
    let entry: Entry
    let siblings: [Entry]

    @State private var displayedEntry: Entry?

    private var current: Entry {
        displayedEntry ?? entry
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.title ?? "Untitled")
                    .font(.system(size: 24, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    if let feedTitle = current.feed?.title {
                        Text(feedTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    if let author = current.author, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Text(current.publishedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }

                // Source pills
                if siblings.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(siblings) { sibling in
                            let isActive = sibling.id == current.id
                            Button {
                                displayedEntry = sibling
                            } label: {
                                Text(domainName(for: sibling))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        isActive ? activePillColor : inactivePillColor,
                                        in: RoundedRectangle(cornerRadius: 4)
                                    )
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                // Article body as plain text (HTML stripped)
                Text(stripHTML(current.bestBody))
                    .font(.system(size: 16))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: 660, alignment: .leading)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .id(entry.feedbinEntryID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Article: \(current.title ?? "Untitled")")
        .accessibilityIdentifier("entry.detail")
        .onChange(of: entry) {
            displayedEntry = nil
        }
    }

    private func domainName(for entry: Entry) -> String {
        let urlString = entry.feed?.siteURL ?? entry.url
        guard let url = URL(string: urlString), let host = url.host() else {
            return entry.feed?.title ?? "unknown"
        }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    private func stripHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Preview

#Preview("Article Detail with Sources") {
    articleDetailPreview()
}

@MainActor
private func articleDetailPreview() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config)
    let context = container.mainContext

    let feed1 = Feed(
        feedbinSubscriptionID: 1, feedbinFeedID: 1,
        title: "The Verge", feedURL: "https://theverge.com/rss",
        siteURL: "https://theverge.com", createdAt: .now
    )
    let feed2 = Feed(
        feedbinSubscriptionID: 2, feedbinFeedID: 2,
        title: "Ars Technica", feedURL: "https://arstechnica.com/rss",
        siteURL: "https://arstechnica.com", createdAt: .now
    )
    context.insert(feed1)
    context.insert(feed2)

    let entry1 = Entry(
        feedbinEntryID: 1, title: "Apple unveils M5 Ultra chip with record-breaking AI performance",
        author: "Tom Warren", url: "https://example.com/1",
        content: "<p>Apple today announced the M5 Ultra, its most powerful chip ever.</p>",
        summary: nil, extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-3600), createdAt: .now
    )
    entry1.feed = feed1
    entry1.storyKey = "apple-m5-ultra"
    context.insert(entry1)

    let entry2 = Entry(
        feedbinEntryID: 2, title: "Apple's M5 Ultra: everything you need to know",
        author: nil, url: "https://example.com/2",
        content: "<p>Ars Technica's take on the new M5 Ultra chip.</p>",
        summary: nil, extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-1800), createdAt: .now
    )
    entry2.feed = feed2
    entry2.storyKey = "apple-m5-ultra"
    context.insert(entry2)

    return EntryDetailView(entry: entry1, siblings: [entry1, entry2])
        .modelContainer(container)
        .frame(width: 600, height: 500)
}
