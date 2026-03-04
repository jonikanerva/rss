import SwiftUI
import WebKit

struct EntryDetailView: View {
    let entry: Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.title ?? "Untitled")
                        .font(.title)
                        .fontWeight(.bold)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 16) {
                        if let feedTitle = entry.feed?.title {
                            Label(feedTitle, systemImage: "dot.radiowaves.up.forward")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let author = entry.author, !author.isEmpty {
                            Label(author, systemImage: "person")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.publishedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    if !entry.categoryLabels.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.categoryLabels, id: \.self) { label in
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }
                }

                Divider()

                // Body content
                HTMLContentView(html: entry.bestBody)
                    .frame(minHeight: 400)
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
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
                padding: 0;
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
