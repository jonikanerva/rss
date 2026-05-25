import SwiftData
import SwiftUI
import os.signpost

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
  /// In-flight article-click signpost interval handed down from `ContentView`.
  /// When the rendered HTML lands in `ArticleWebContainer.task(id:)` — i.e.
  /// the moment the user-perceptive content is ready to paint — the end is
  /// emitted and `onArticleClickEnded` fires so `ContentView` can nil out
  /// its `@State`. The interval therefore measures click → HTML-ready
  /// latency, not just the next runloop tick.
  let pendingArticleClickInterval: OSSignpostIntervalState?
  let onArticleClickEnded: () -> Void
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(AppFontSettings.self)
  private var fontSettings

  /// View-level cache of decoded reader blocks. Lives here (not on `@Model Entry`) so
  /// persistence and rendering stay in separate layers. Re-decodes when the persisted
  /// JSON changes — either because the user navigated to a different entry or because
  /// `DataWriter` updated `articleBlocksData` in place (e.g. after Mercury Parser
  /// extraction). A single `.task(id:)` trigger covers both paths.
  @State
  private var blocks: [ArticleBlock] = []

  init(
    entry: Entry,
    viewMode: ArticleViewMode,
    pendingArticleClickInterval: OSSignpostIntervalState? = nil,
    onArticleClickEnded: @escaping () -> Void = {}
  ) {
    self.entry = entry
    self.viewMode = viewMode
    self.pendingArticleClickInterval = pendingArticleClickInterval
    self.onArticleClickEnded = onArticleClickEnded
  }

  var body: some View {
    Group {
      switch viewMode {
      case .web:
        ArticleWebContainer(
          entry: entry,
          pendingArticleClickInterval: pendingArticleClickInterval,
          onArticleClickEnded: onArticleClickEnded
        )
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
        .font(fontSettings.metadata)
        .foregroundStyle(.secondary)

      // Title
      Text(entry.title ?? "Untitled")
        .font(fontSettings.articleTitle)
        .fixedSize(horizontal: false, vertical: true)

      // Favicon + author/domain
      HStack(alignment: .center, spacing: 8) {
        FaviconView(feed: entry.feed)
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
  /// Forwarded from `EntryDetailView`. See the doc comment there — the end
  /// fires when the new entry's HTML is ready to hand to the WKWebView.
  /// Only ends when the *entry* actually changes; font-size changes also
  /// trigger this `.task` but should not close the click interval (they
  /// were not initiated by an article click).
  let pendingArticleClickInterval: OSSignpostIntervalState?
  let onArticleClickEnded: () -> Void

  @Environment(AppFontSettings.self)
  private var fontSettings
  @State
  private var renderedHTML: String?
  /// Tracks which entry the most recent render completed against. Lets the
  /// signpost end distinguish a real entry switch (close the click interval)
  /// from a font-size-only re-render (interval not initiated by a click, so
  /// must not be closed here). Nil before the first render lands.
  @State
  private var lastRenderedEntryID: Int?

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
    // Re-key on `(entry, textSize)` so changing the picker re-renders the
    // article HTML with the new `--app-scale` value — without changing the
    // selected entry, the user's scroll position is preserved by WKWebView
    // as long as the document stays the same shape (same DOM, larger text).
    .task(id: renderKey) {
      // Detail-render signpost: measures the off-MainActor HTML render itself
      // (regex sanitisation + template injection on a detached task), not the
      // click → task latency. Paired with the sidebar/article-click intervals
      // in ContentView so Instruments shows commit + render as separate lanes.
      let renderState = perfSignposter.beginInterval(
        PerformanceSignpostName.detailRender
      )
      // Snapshot the current entry's ID so we can decide later whether
      // the article-click interval should end on this pass (real entry
      // switch) or be left alone (font-size-only re-render).
      let entryAtStart = entry.feedbinEntryID
      // Keep the previous article's HTML visible while the new one renders
      // (~5ms). This avoids a spinner flash on every arrow-key navigation —
      // HIG advises against loading indicators for <100ms operations.
      // Stale-HTML protection still holds:
      //   • ArticleWebView's currentEntryID guard blocks loading the wrong
      //     entry into WKWebView.
      //   • The Task.isCancelled check below blocks a late render from
      //     overwriting @State after the user has moved on.
      let html = await renderHTML(for: entry, scaleFactor: fontSettings.textSize.scaleFactor)
      guard !Task.isCancelled else {
        perfSignposter.endInterval(PerformanceSignpostName.detailRender, renderState)
        // Cancellation means the user moved on (clicked another entry,
        // cleared selection, or switched text size mid-render). The
        // article-click interval is closed by `ContentView.onChange(of:
        // selectedEntry)` — either by the stale-guard on a new selection
        // or by the explicit close on selection-clear. Closing it here
        // too would double-end the same `OSSignpostIntervalState`.
        return
      }
      renderedHTML = html
      // Article-click signpost end: only when the entry actually changed —
      // font-size-only re-renders re-fire this task but were not initiated
      // by an article click and so must not close the interval. The
      // `pendingArticleClickInterval` snapshot captured at task start is
      // still valid here because no other code path closes it on the
      // success route.
      if entryAtStart != lastRenderedEntryID {
        endPendingArticleClickInterval()
      }
      lastRenderedEntryID = entryAtStart
      perfSignposter.endInterval(PerformanceSignpostName.detailRender, renderState)
    }
  }

  /// Sibling of `EntryListView.endPendingSidebarClickInterval()`. Closes the
  /// click interval and notifies `ContentView` so it can drop its `@State`.
  private func endPendingArticleClickInterval() {
    guard let state = pendingArticleClickInterval else { return }
    perfSignposter.endInterval(PerformanceSignpostName.articleClick, state)
    onArticleClickEnded()
  }

  /// Composite re-render key: a new entry obviously triggers a fresh render,
  /// and a new text size triggers a re-render with an updated `--app-scale`.
  /// Encoding both in one key keeps `.task(id:)` semantics simple.
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
  // `.dynamicTypeSize(_:)` propagates the environment value but does not
  // re-resolve system fonts on macOS, so a `.accessibility3` modifier
  // here would render identically to `.medium`. Inject the largest
  // `AppFontSettings` instead — that is the mechanism shipped code uses,
  // so the preview reflects what a user picking *Huge* actually sees.
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
    .modelContainer(container)
    .frame(width: 600, height: 500)
}
