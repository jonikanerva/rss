import SwiftData
import SwiftUI

// MARK: - Shared Detail Date Formatting

/// Shared date formatting for article detail views (both SwiftUI and WebView).
///
/// Marked `nonisolated` so the article HTML renderer can invoke it from a
/// background task. Composed from value-type `Date.FormatStyle` pieces instead
/// of a shared `DateFormatter` so there is no mutable state to make
/// `Sendable`-safe, matching `formatEntryDate` in `EntryFormatting.swift`.
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

  /// View-level cache of decoded reader blocks. Lives here (not on `@Model Entry`) so
  /// persistence and rendering stay in separate layers. Re-decodes when the persisted
  /// JSON changes — either because the user navigated to a different entry or because
  /// `DataWriter` updated `articleBlocksData` in place (e.g. after Mercury Parser
  /// extraction). A single `.task(id:)` trigger covers both paths.
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
      // JSON decode for 30–100 KB blobs runs in <1 ms, so doing it synchronously in
      // the task body is preferable to dispatching to a background priority — async
      // here would introduce a visible empty-state flash on every entry switch.
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

// MARK: - Article Web Container

/// Hosts `ArticleWebView` and renders the article HTML off the MainActor.
///
/// The regex sanitization and template-injection passes used to run inside
/// `ArticleWebView.updateNSView`, on MainActor. Moving them here behind a
/// `Task.detached` keeps the MainActor free for view diffing while the
/// article switches. A `ProgressView` is shown only on the very first
/// render (when `renderedHTML` is still `nil`); subsequent article switches
/// keep the previous article visible until the new HTML lands (~5ms),
/// avoiding spinner flashes during fast arrow-key navigation.
private struct ArticleWebContainer: View {
  let entry: Entry

  @State
  private var renderedHTML: String?

  /// Bundle resources are immutable — load once on first access, reuse forever.
  /// Static so the cost is paid only at first article view, never per render.
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
    .task(id: entry.feedbinEntryID) {
      // Keep the previous article's HTML visible while the new one renders
      // (~5ms). This avoids a spinner flash on every arrow-key navigation —
      // HIG advises against loading indicators for <100ms operations.
      // Stale-HTML protection still holds:
      //   • ArticleWebView's currentEntryID guard blocks loading the wrong
      //     entry into WKWebView.
      //   • The Task.isCancelled check below blocks a late render from
      //     overwriting @State after the user has moved on.
      let html = await renderHTML(for: entry)
      guard !Task.isCancelled else { return }
      renderedHTML = html
    }
  }

  /// Snapshot every MainActor-only value from `entry` and `entry.feed`, then
  /// hand the plain `Sendable` values to a detached task for the heavy work.
  private func renderHTML(for entry: Entry) async -> String {
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
        template: template,
        css: css
      )
    }.value
  }
}

// MARK: - Preview

#Preview("Article Detail with Sources") {
  articleDetailPreview()
}

@MainActor
private func articleDetailPreview() -> some View {
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
    .modelContainer(container)
    .frame(width: 600, height: 500)
}
