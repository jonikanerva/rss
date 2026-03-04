import SwiftUI
import WebKit

struct EntryDetailView: View {
    let entry: Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title ?? "Untitled")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    HStack(spacing: 12) {
                        if let feedTitle = entry.feed?.title {
                            Label(feedTitle, systemImage: "dot.radiowaves.up.forward")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let author = entry.author {
                            Label(author, systemImage: "person")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.publishedAt, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    if !entry.categoryLabels.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.categoryLabels, id: \.self) { label in
                                Text(label)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }

                    Divider()
                }

                // Body content
                HTMLContentView(html: entry.bestBody)
                    .frame(minHeight: 400)
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem {
                if let url = URL(string: entry.url) {
                    Link(destination: url) {
                        Image(systemName: "safari")
                    }
                    .help("Open in browser")
                }
            }
        }
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
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 16px;
                line-height: 1.6;
                color: #1d1d1f;
                max-width: 720px;
                margin: 0;
                padding: 0;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #f5f5f7; }
                a { color: #6eb6ff; }
            }
            img { max-width: 100%; height: auto; border-radius: 8px; }
            a { color: #0066cc; }
            pre, code {
                background: rgba(128, 128, 128, 0.1);
                border-radius: 4px;
                padding: 2px 6px;
                font-size: 14px;
            }
            pre { padding: 12px; overflow-x: auto; }
            blockquote {
                border-left: 3px solid rgba(128, 128, 128, 0.3);
                margin-left: 0;
                padding-left: 16px;
                color: rgba(128, 128, 128, 0.8);
            }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
}
