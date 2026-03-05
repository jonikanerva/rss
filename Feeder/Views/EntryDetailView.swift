import SwiftUI
import SwiftData
import WebKit

// MARK: - Source pill colors

private let activePillColor = Color(hex: 0xE8866A)
private let inactivePillColor = Color(hex: 0x3A3A3C)

struct EntryDetailView: View {
    @Binding var selectedEntry: Entry?
    @Query(sort: \Entry.publishedAt, order: .reverse) private var allEntries: [Entry]

    /// The entry currently being displayed (may differ from selectedEntry when switching sources).
    @State private var displayedEntry: Entry?

    /// Sibling entries sharing the same storyKey (from different sources).
    private var siblingEntries: [Entry] {
        guard let entry = displayedEntry ?? selectedEntry,
              let key = entry.storyKey, !key.isEmpty else { return [] }
        return allEntries.filter { $0.storyKey == key }
    }

    private var entry: Entry? {
        displayedEntry ?? selectedEntry
    }

    var body: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 0) {
                // Fixed header
                VStack(alignment: .leading, spacing: 12) {
                    // Title
                    Text(entry.title ?? "Untitled")
                        .font(.system(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    // Byline
                    HStack(spacing: 12) {
                        if let feedTitle = entry.feed?.title {
                            Text(feedTitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        if let author = entry.author, !author.isEmpty {
                            Text(author)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.publishedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    // Source pills (sibling entries from same story)
                    if siblingEntries.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(siblingEntries) { sibling in
                                    let isActive = sibling.id == entry.id
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
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 16)

                // Scrollable body content — fills remaining space
                HTMLContentView(html: entry.bestBody)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Article: \(entry.title ?? "Untitled")")
            .onChange(of: selectedEntry) {
                displayedEntry = nil
            }
        }
    }

    /// Extract domain from entry's URL or feed's siteURL, e.g. "theverge.com"
    private func domainName(for entry: Entry) -> String {
        let urlString = entry.feed?.siteURL ?? entry.url
        guard let url = URL(string: urlString), let host = url.host() else {
            return entry.feed?.title ?? "unknown"
        }
        // Strip "www." prefix
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }
}

/// Renders HTML content using WKWebView.
struct HTMLContentView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            :root {
                color-scheme: light dark;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 16px;
                line-height: 1.7;
                color: #1d1d1f;
                max-width: 660px;
                margin: 0;
                padding: 0 32px 32px 32px;
                -webkit-font-smoothing: antialiased;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #f5f5f7; }
                a { color: #6eb6ff; }
            }
            p { margin: 0 0 1em 0; }
            h1, h2, h3, h4, h5, h6 {
                font-weight: 600;
                line-height: 1.3;
                margin: 1.5em 0 0.5em 0;
            }
            h1 { font-size: 1.4em; }
            h2 { font-size: 1.2em; }
            h3 { font-size: 1.1em; }
            img {
                max-width: 100%;
                height: auto;
                border-radius: 8px;
                margin: 0.5em 0;
            }
            a { color: #0066cc; text-decoration: none; }
            a:hover { text-decoration: underline; }
            pre, code {
                font-family: "SF Mono", Menlo, monospace;
                background: rgba(128, 128, 128, 0.08);
                border-radius: 4px;
                font-size: 0.9em;
            }
            code { padding: 2px 5px; }
            pre {
                padding: 14px;
                overflow-x: auto;
                line-height: 1.5;
            }
            pre code { padding: 0; background: none; }
            blockquote {
                border-left: 3px solid rgba(128, 128, 128, 0.2);
                margin: 1em 0;
                padding: 0 0 0 16px;
                color: rgba(128, 128, 128, 0.8);
            }
            hr {
                border: none;
                border-top: 1px solid rgba(128, 128, 128, 0.15);
                margin: 1.5em 0;
            }
            table {
                border-collapse: collapse;
                margin: 1em 0;
                width: 100%;
            }
            th, td {
                border: 1px solid rgba(128, 128, 128, 0.2);
                padding: 8px 12px;
                text-align: left;
            }
            th { font-weight: 600; }
            figure { margin: 1em 0; }
            figcaption {
                font-size: 0.85em;
                color: rgba(128, 128, 128, 0.7);
                margin-top: 0.5em;
            }
            ul, ol { padding-left: 1.5em; }
            li { margin-bottom: 0.3em; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
}

// MARK: - Preview

#Preview("Article Detail with Sources") {
    @Previewable @State var selected: Entry?

    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, StoryGroup.self, configurations: config)
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

    selected = entry1

    return EntryDetailView(selectedEntry: $selected)
        .modelContainer(container)
        .frame(width: 600, height: 500)
}
