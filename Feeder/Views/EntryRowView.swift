import AppKit
import SwiftUI
import os.signpost

// MARK: - Entry Row View

/// One article-list row, rendered ENTIRELY from its `EntryRowDTO` value
/// snapshot plus the pre-decoded favicon image (issue #148). No
/// `modelContext`, no `model(for:)`, no `entry.feed` relationship fault — the
/// row performs zero store access on MainActor. The optimistic
/// `pendingReadIDs` overlay dims a just-opened row before the committed
/// `isRead` lands in a refetched DTO.
///
/// Layout constants live in `EntryRowMetrics` (issue #170). The text column
/// has a FIXED height (`AppFontSettings.entryRowTextColumnHeight`), so the
/// row's natural height equals the list's row-height floor minus the margin
/// for every content shape. Inside the column the title takes one or two
/// lines, the domain keeps its reserved line, and the summary fills the rest:
/// three lines under a one-line title, two under a two-line title. Only the
/// summary yields, by ellipsis truncation at a line end; nothing is clipped.
struct EntryRowView: View {
  let row: EntryRowDTO
  let faviconImage: NSImage?
  @Environment(\.pendingReadIDs)
  private var pendingReadIDs
  @Environment(AppFontSettings.self)
  private var fontSettings

  private var isRead: Bool { row.isRead || pendingReadIDs.contains(row.feedbinEntryID) }

  var body: some View {
    // Whole-list-re-render check (issue #146, DIAGNOSTIC-ONLY): one event per
    // body evaluation. Events inside a `structuralReload` window reveal whether
    // the List rebuilds every row or only the visible ones. Mirrors the SwiftUI
    // `Self._printChanges()` body-diagnostic idiom; zero-cost with no profiler.
    let _ = perfSignposter.emitEvent(PerformanceSignpostName.rowBodyBuild)
    return HStack(alignment: .top, spacing: EntryRowMetrics.faviconSpacing) {
      // Favicon — own vertical column
      FaviconView(image: faviconImage, fallbackLetter: row.feedInitial)
        .frame(width: EntryRowMetrics.faviconSize, height: EntryRowMetrics.faviconSize)
        .padding(.top, EntryRowMetrics.faviconTopPadding)

      // All text content aligned to the right of the icon. The column has a
      // FIXED height (issue #170), so the row's natural height is the same
      // for every content shape and a lost row re-measure in the AppKit
      // bridge cannot clip anything. Layout priorities settle the split:
      // the title row (2) is offered the column minus the other slots'
      // minimum heights and takes one or two lines; the domain (1) takes
      // its reserved line; the summary (0) receives the exact remainder and
      // truncates with an ellipsis at a line end. With equal priorities
      // SwiftUI would split the free space evenly between the title and
      // the summary, and a two-line title would collapse to one line at
      // every text size.
      VStack(alignment: .leading, spacing: EntryRowMetrics.textSpacing) {
        // Title + time
        HStack(alignment: .top, spacing: EntryRowMetrics.titleTimeSpacing) {
          Text(row.title ?? "Untitled")
            .font(fontSettings.rowTitle)
            // The semibold/regular swap on `isRead` carries the unread/read
            // visual hierarchy the rest of the row design depends on. It has
            // no height effect: both weights report the same line metrics.
            .fontWeight(isRead ? .regular : .semibold)
            .lineLimit(EntryRowMetrics.titleLineLimit)
            .foregroundStyle(isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)

          Spacer()

          Text(row.formattedPublishedTime)
            .font(fontSettings.rowFeedName)
            .foregroundStyle(.tertiary)
        }
        .layoutPriority(2)

        // Domain line. A row without a domain renders the placeholder space,
        // which reserves the font's own line height (an empty string would
        // reserve 14 pt at every size), so the space left for the summary is
        // the same with and without a domain; a long domain truncates in the
        // middle instead of wrapping so the slot stays one line tall.
        Text(row.displayDomain?.lowercased() ?? EntryRowMetrics.reservedDomainPlaceholder)
          .font(fontSettings.rowFeedName)
          .lineLimit(EntryRowMetrics.domainLineLimit, reservesSpace: true)
          .truncationMode(.middle)
          .foregroundStyle(FontTheme.domainPillColor)
          .layoutPriority(1)

        // Summary excerpt (summary-preferred / plainText fallback, applied at
        // projection time by `rowExcerpt`). Fills the rest of the column:
        // three lines under a one-line title, two under a two-line title
        // (`excerptLineLimit`). An empty excerpt leaves its blank space at
        // the bottom of the column, never between the title and the domain.
        Text(row.excerpt)
          .font(fontSettings.rowSummary)
          .lineLimit(EntryRowMetrics.excerptLineLimit)
          .foregroundStyle(.tertiary)
      }
      .frame(height: fontSettings.entryRowTextColumnHeight, alignment: .top)
    }
    .padding(.vertical, EntryRowMetrics.verticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isRead ? (row.title ?? "Untitled") : "Unread, \(row.title ?? "Untitled")")
    .accessibilityIdentifier("entry.row.\(row.feedbinEntryID)")
  }
}

// MARK: - Favicon View

/// The 24×24 favicon slot: a pre-decoded image when the `FaviconStore` has
/// one, otherwise the feed-initial fallback in the SAME fixed box (no layout
/// shift on cache miss). The render-time `NSImage(data:)` decode that used to
/// live here is gone — decoding happens once per feed in `FaviconStore`.
struct FaviconView: View {
  let image: NSImage?
  let fallbackLetter: String

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
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
  entryRowPreview(
    row: unreadPreviewRow(), fontSettings: AppFontSettings(), faviconImage: previewFaviconImage())
}

#Preview("Read Entry") {
  entryRowPreview(
    row: readPreviewRow(), fontSettings: AppFontSettings(), faviconImage: previewFaviconImage())
}

#Preview("Unread Entry — Huge Text") {
  // `.dynamicTypeSize(_:)` propagates the environment value but does not
  // re-resolve system fonts on macOS, so it makes the preview look
  // identical to `.medium`. Inject `AppFontSettings(textSize: .xxLarge)`
  // through the view's regular environment slot instead — that is the
  // mechanism shipped code uses, so the preview actually shows the
  // largest layout reviewers ship to users.
  entryRowPreview(
    row: unreadPreviewRow(), fontSettings: AppFontSettings(textSize: .xxLarge),
    faviconImage: previewFaviconImage())
}

#Preview("Unread Entry — Initials Fallback") {
  // No favicon image: the fixed 24×24 slot renders the feed-initial fallback
  // with no layout shift relative to the image case above.
  entryRowPreview(row: unreadPreviewRow(), fontSettings: AppFontSettings())
}

#Preview("Short Title — Three Excerpt Lines") {
  // A one-line title leaves one title line free; the summary takes it and
  // shows three lines, the third with an ellipsis. No blank line between
  // the title and the domain; the row is as tall as the two-line case.
  entryRowPreview(
    row: shortTitlePreviewRow(), fontSettings: AppFontSettings(), faviconImage: previewFaviconImage())
}

#Preview("Short Title — Three Excerpt Lines, Huge Text") {
  // Same shape at the largest text size: the third summary line still fits
  // (the title line height is at least the summary line height at every
  // size, `EntryRowMetricsTests`).
  entryRowPreview(
    row: shortTitlePreviewRow(), fontSettings: AppFontSettings(textSize: .xxLarge),
    faviconImage: previewFaviconImage())
}

/// A programmatically drawn stand-in favicon so the base previews cover the
/// favicon-image SUCCESS state — `FaviconStore`'s primary render state — while
/// the Initials Fallback preview keeps the distinct nil-image case.
@MainActor
private func previewFaviconImage() -> NSImage {
  let image = NSImage(size: NSSize(width: 24, height: 24))
  image.lockFocus()
  NSColor.systemIndigo.setFill()
  NSRect(x: 0, y: 0, width: 24, height: 24).fill()
  NSColor.white.setFill()
  NSRect(x: 6, y: 6, width: 12, height: 12).fill()
  image.unlockFocus()
  return image
}

/// Container-free row previews (issue #148): the row renders from a DTO value
/// alone. Only the `PersistentIdentifier` needs minting (it has no public
/// initializer); every rendered field is set right here.
@MainActor
private func unreadPreviewRow() -> EntryRowDTO {
  EntryRowDTO(
    persistentID: PreviewSupport.mintEntryIdentifiers(count: 1)[0],
    feedbinEntryID: 1,
    title: "Goat Simulator maker Coffee Stain to close its mobile studio",
    formattedPublishedTime: "09.30",
    displayDomain: "mobilegamer.biz",
    excerpt: "Coffee Stain is closing its mobile development arm in Malmö, Sweden.",
    isRead: false,
    publishedAt: .now.addingTimeInterval(-3600),
    feedFeedbinID: 1,
    feedInitial: "M"
  )
}

@MainActor
private func shortTitlePreviewRow() -> EntryRowDTO {
  EntryRowDTO(
    persistentID: PreviewSupport.mintEntryIdentifiers(count: 1)[0],
    feedbinEntryID: 3,
    title: "Coffee Stain closes studio",
    formattedPublishedTime: "10.15",
    displayDomain: "mobilegamer.biz",
    excerpt:
      "Coffee Stain is closing its mobile development arm in Malmö, Sweden, after a review of its "
      + "publishing plans. The studio's current projects move to the parent company, and the team of "
      + "about thirty people is offered roles elsewhere in the group.",
    isRead: false,
    publishedAt: .now.addingTimeInterval(-1800),
    feedFeedbinID: 1,
    feedInitial: "M"
  )
}

@MainActor
private func readPreviewRow() -> EntryRowDTO {
  EntryRowDTO(
    persistentID: PreviewSupport.mintEntryIdentifiers(count: 1)[0],
    feedbinEntryID: 2,
    title: "EU passes sweeping AI regulation requiring model transparency",
    formattedPublishedTime: "08.30",
    displayDomain: "arstechnica.com",
    excerpt: "The European Union has approved comprehensive AI legislation.",
    isRead: true,
    publishedAt: .now.addingTimeInterval(-90_000),
    feedFeedbinID: 2,
    feedInitial: "A"
  )
}

@MainActor
private func entryRowPreview(
  row: EntryRowDTO, fontSettings: AppFontSettings, faviconImage: NSImage? = nil
) -> some View {
  EntryRowView(row: row, faviconImage: faviconImage)
    .environment(fontSettings)
    .frame(width: 380)
    .padding()
}
