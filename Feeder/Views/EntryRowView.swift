import AppKit
import SwiftUI
import os.signpost

// MARK: - Entry Row View

/// One article-list row, rendered entirely from its `EntryRowDTO` snapshot and
/// the pre-decoded favicon image: no `modelContext`, no `model(for:)`, no
/// relationship fault, and no store access on MainActor. The optimistic
/// `pendingReadIDs` overlay dims a just-opened row before the committed state
/// lands in a refetched DTO.
///
/// Layout constants live in `EntryRowMetrics`. The text column has a fixed
/// height, so the row's natural height is the same for every content shape.
/// Inside it the title takes one or two lines, the domain keeps its reserved
/// line, and the summary fills the rest. Only the summary yields, by ellipsis
/// at a line end; nothing is clipped.
struct EntryRowView: View {
  let row: EntryRowDTO
  let faviconImage: NSImage?
  @Environment(\.pendingReadIDs)
  private var pendingReadIDs
  @Environment(AppFontSettings.self)
  private var fontSettings

  private var isRead: Bool { row.isRead || pendingReadIDs.contains(row.feedbinEntryID) }

  /// Domain line text. The reader maps a stored empty domain to `nil`, and the
  /// view guards the empty string too, because previews and tests build DTOs
  /// directly.
  private var domainText: String {
    guard let domain = row.displayDomain, !domain.isEmpty else {
      return EntryRowMetrics.reservedDomainPlaceholder
    }
    return domain.lowercased()
  }

  var body: some View {
    // One event per body evaluation. Events inside a `structuralReload` window
    // reveal whether the `List` rebuilds every row or only the visible ones.
    // Diagnostic only, and zero-cost with no profiler attached.
    let _ = perfSignposter.emitEvent(PerformanceSignpostName.rowBodyBuild)
    return HStack(alignment: .top, spacing: EntryRowMetrics.faviconSpacing) {
      // Favicon — own vertical column
      FaviconView(image: faviconImage, fallbackLetter: row.feedInitial)
        .frame(width: EntryRowMetrics.faviconSize, height: EntryRowMetrics.faviconSize)
        .padding(.top, EntryRowMetrics.faviconTopPadding)

      // The column has a fixed height, and the layout priorities settle the
      // split: the title is offered the column minus the other slots' minimum
      // heights, the domain takes its reserved line, and the summary gets the
      // remainder. With equal priorities SwiftUI splits the free space evenly
      // and a two-line title collapses to one line at every text size.
      VStack(alignment: .leading, spacing: EntryRowMetrics.textSpacing) {
        // Title + time
        HStack(alignment: .top, spacing: EntryRowMetrics.titleTimeSpacing) {
          Text(row.title ?? "Untitled")
            .font(fontSettings.rowTitle)
            // The weight swap carries the unread and read hierarchy. It has no
            // height effect: both weights report the same line metrics.
            .fontWeight(isRead ? .regular : .semibold)
            .lineLimit(EntryRowMetrics.titleLineLimit)
            .foregroundStyle(isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)

          Spacer()

          Text(row.formattedPublishedTime)
            .font(fontSettings.rowFeedName)
            .foregroundStyle(.tertiary)
        }
        .layoutPriority(2)

        // A row without a domain renders the placeholder space, which reserves
        // the font's own line height, so the summary gets the same space either
        // way. A long domain truncates in the middle rather than wrapping, so
        // the slot stays one line tall.
        Text(domainText)
          .font(fontSettings.rowFeedName)
          .lineLimit(EntryRowMetrics.domainLineLimit, reservesSpace: true)
          .truncationMode(.middle)
          .foregroundStyle(FontTheme.domainPillColor)
          .layoutPriority(1)

        // The summary fills the rest of the column. An empty excerpt leaves its
        // blank space at the bottom of the column, never between the title and
        // the domain.
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

/// The favicon slot: a pre-decoded image when `FaviconStore` has one, and the
/// feed-initial fallback in the same fixed box otherwise, so a cache miss
/// causes no layout shift. The decode happens once per feed in the store, never
/// here.
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
  // `.dynamicTypeSize(_:)` would render identically to `.medium` on macOS, so
  // the preview injects the font settings the shipped code uses.
  entryRowPreview(
    row: unreadPreviewRow(), fontSettings: AppFontSettings(textSize: .xxLarge),
    faviconImage: previewFaviconImage())
}

#Preview("Unread Entry — Initials Fallback") {
  // No favicon image: the fixed slot renders the feed-initial fallback with no
  // layout shift against the image case above.
  entryRowPreview(row: unreadPreviewRow(), fontSettings: AppFontSettings())
}

#Preview("Short Title — Three Excerpt Lines") {
  // A one-line title leaves one title line free, and the summary takes it. No
  // blank line between the title and the domain, and the row stays as tall as
  // the two-line case.
  entryRowPreview(
    row: shortTitlePreviewRow(), fontSettings: AppFontSettings(), faviconImage: previewFaviconImage())
}

#Preview("Short Title — Three Excerpt Lines, Huge Text") {
  // The same shape at the largest text size: the extra summary line still fits,
  // because the title line height is at least the summary line height at every
  // size (`EntryRowMetricsTests`).
  entryRowPreview(
    row: shortTitlePreviewRow(), fontSettings: AppFontSettings(textSize: .xxLarge),
    faviconImage: previewFaviconImage())
}

/// A drawn stand-in favicon, so the base previews cover the favicon-image
/// state while the fallback preview keeps the nil-image case.
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

/// Container-free row previews: the row renders from a DTO value alone. Only
/// the `PersistentIdentifier` needs minting, because it has no public
/// initializer.
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
