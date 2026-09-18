import SwiftData
import SwiftUI
import os.signpost

// MARK: - Shared Detail Date Formatting

/// Shared date formatting for the article detail surfaces. `nonisolated`, so
/// the HTML renderer can call it from a background task, and built from
/// value-type format styles so there is no mutable state to make `Sendable`.
enum DetailDateFormatting {
  nonisolated static func formatDate(_ date: Date) -> String {
    let posix = Locale(identifier: "en_US_POSIX")
    let weekday = date.formatted(.dateTime.weekday(.wide).locale(posix))
    let day = Calendar.current.component(.day, from: date)
    let month = date.formatted(.dateTime.month(.wide).locale(posix))
    let year = date.formatted(.dateTime.year(.defaultDigits).locale(posix))
    let time = date.formatted(
      .dateTime
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .locale(posix)
    )
    return "\(weekday) \(day). \(month) \(year) at \(time)"
  }
}

struct EntryDetailView: View {
  let entry: Entry
  let viewMode: ArticleViewMode
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(AppFontSettings.self)
  private var fontSettings
  @Environment(FaviconStore.self)
  private var faviconStore

  /// View-level cache of the decoded reader blocks, kept out of the model so
  /// persistence and rendering stay in separate layers. One `.task(id:)`
  /// re-decodes whenever the persisted JSON changes, whether the user navigated
  /// or the writer updated the blocks in place.
  @State
  private var blocks: [ArticleBlock] = []

  var body: some View {
    Group {
      switch viewMode {
      case .web:
        ArticleWebContainer(entry: entry)
      case .reader:
        readerView
      }
    }
    // No `.id(...)` here: SwiftUI must diff the bindings rather than tear the
    // web view down. `ArticleWebView` already guards against a duplicate load.
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

        // Article body — structured blocks decoded from `entry.articleBlocksData`.
        ArticleBlockView(blocks: blocks)
          .textSelection(.enabled)
      }
      .frame(maxWidth: 610, alignment: .leading)
      .padding(.horizontal, 50)
      .padding(.top, 24)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .task(id: entry.articleBlocksData) {
      // The decode is fast enough to run synchronously here. Dispatching it to a
      // background priority would flash the empty state on every entry switch.
      blocks = decodeBlocks(
        data: entry.articleBlocksData,
        fallbackPlainText: entry.plainText,
        fallbackURL: entry.url
      )
    }
  }

  private var articleHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Date + time
      Text(DetailDateFormatting.formatDate(entry.publishedAt))
        .font(fontSettings.metadata)
        .foregroundStyle(.secondary)

      // Title
      Text(entry.title ?? "Untitled")
        .font(fontSettings.articleTitle)
        .fixedSize(horizontal: false, vertical: true)

      // The detail pane holds the one live `Entry`, so reading `entry.feed`
      // here is the sanctioned one-shot boundary resolve. The image comes from
      // the shared store, and a cache miss renders the initials fallback.
      HStack(alignment: .center, spacing: 8) {
        FaviconView(
          image: faviconStore.image(for: entry.feed?.feedbinFeedID),
          fallbackLetter: feedInitial(from: entry.feed?.title)
        )
        .frame(width: 20, height: 20)

        VStack(alignment: .leading, spacing: 2) {
          if let author = entry.author, !author.isEmpty {
            Text(author)
              .font(fontSettings.metadata)
              .foregroundStyle(.secondary)
          }
          if let domain = entry.displayDomain, !domain.isEmpty {
            Text(domain.lowercased())
              .font(fontSettings.metadata)
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

// MARK: - Article Web Container

/// Hosts `ArticleWebView` and renders the article HTML off MainActor, so the
/// regex sanitisation and template injection never block view diffing during an
/// article switch. The spinner appears only on the first render; a later switch
/// keeps the previous article visible until the new HTML lands, so fast
/// keyboard navigation never flashes.
private struct ArticleWebContainer: View {
  let entry: Entry

  @Environment(AppFontSettings.self)
  private var fontSettings
  @State
  private var renderedHTML: String?

  /// Bundle resources are immutable, so this loads once on first access. Static,
  /// so the cost is never paid per render.
  nonisolated static let articleTemplate: String = loadStaticResource(
    "article-template", ext: "html"
  )
  nonisolated static let articleCSS: String = loadStaticResource(
    "article-style", ext: "css"
  )

  var body: some View {
    Group {
      if let renderedHTML {
        ArticleWebView(entry: entry, renderedHTML: renderedHTML)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // Re-keying on the text size re-renders the HTML with a new scale. The
    // selected entry does not change, so the web view keeps the scroll position
    // while the document keeps its shape.
    .task(id: renderKey) {
      // Measures the off-MainActor render alone, not the click-to-task latency,
      // so commit and render stay separate lanes in a trace.
      let renderState = perfSignposter.beginInterval(
        PerformanceSignpostName.detailRender
      )
      // Keep the previous article visible while the new one renders: the HIG
      // advises against a loading indicator for an operation this short. Stale
      // HTML is still blocked, by the web view's entry guard and by the
      // cancellation check below.
      let html = await renderHTML(for: entry, scaleFactor: fontSettings.textSize.scaleFactor)
      guard !Task.isCancelled else {
        perfSignposter.endInterval(PerformanceSignpostName.detailRender, renderState)
        return
      }
      renderedHTML = html
      perfSignposter.endInterval(PerformanceSignpostName.detailRender, renderState)
    }
  }

  /// Composite re-render key: a new entry renders fresh HTML, and a new text
  /// size renders it at an updated scale.
  private var renderKey: String {
    "\(entry.feedbinEntryID)|\(fontSettings.textSize.rawValue)"
  }

  /// Snapshot every MainActor-only value from `entry` and `entry.feed`, then
  /// hand the plain `Sendable` values to a detached task for the heavy work.
  private func renderHTML(for entry: Entry, scaleFactor: CGFloat) async -> String {
    let body = entry.feedHTML
    let title = entry.title
    let author = entry.author
    let publishedAt = entry.publishedAt
    let displayDomain = entry.displayDomain
    let faviconBase64 = entry.feed?.faviconData?.base64EncodedString()
    let feedTitleInitial = entry.feed?.title.first
    let template = Self.articleTemplate
    let css = Self.articleCSS

    return await Task.detached(priority: .userInitiated) {
      renderArticleHTML(
        feedHTMLBody: body,
        title: title,
        author: author,
        publishedAt: publishedAt,
        displayDomain: displayDomain,
        faviconBase64: faviconBase64,
        feedTitleInitial: feedTitleInitial,
        scaleFactor: scaleFactor,
        template: template,
        css: css
      )
    }.value
  }
}

// MARK: - Preview

#Preview("Article Detail") {
  articleDetailPreview(fontSettings: AppFontSettings())
}

#Preview("Article Detail — Huge Text") {
  // `.dynamicTypeSize(_:)` would render identically to `.medium` on macOS, so
  // the preview injects the font settings the shipped code uses.
  articleDetailPreview(fontSettings: AppFontSettings(textSize: .xxLarge))
}

@MainActor
private func articleDetailPreview(fontSettings: AppFontSettings) -> some View {
  let container = PreviewSupport.makeContainer()
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
    .environment(fontSettings)
    .environment(FaviconStore())
    .modelContainer(container)
    .frame(width: 600, height: 500)
}
