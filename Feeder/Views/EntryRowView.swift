import AppKit
import SwiftUI

// MARK: - Entry Row View

/// One article-list row, rendered ENTIRELY from its `EntryRowDTO` value
/// snapshot plus the pre-decoded favicon image (issue #148). No
/// `modelContext`, no `model(for:)`, no `entry.feed` relationship fault — the
/// row performs zero store access on MainActor. The optimistic
/// `pendingReadIDs` overlay dims a just-opened row before the committed
/// `isRead` lands in a refetched DTO.
struct EntryRowView: View {
  let row: EntryRowDTO
  let faviconImage: NSImage?
  @Environment(\.pendingReadIDs)
  private var pendingReadIDs
  @Environment(AppFontSettings.self)
  private var fontSettings

  private var isRead: Bool { row.isRead || pendingReadIDs.contains(row.feedbinEntryID) }

  var body: some View {
    HStack(alignment: .top, spacing: 15) {
      // Favicon — own vertical column
      FaviconView(image: faviconImage, fallbackLetter: row.feedInitial)
        .frame(width: 24, height: 24)
        .padding(.top, 2)

      // All text content aligned to the right of the icon
      VStack(alignment: .leading, spacing: 3) {
        // Feed name + time
        HStack(alignment: .top, spacing: 5) {
          Text(row.title ?? "Untitled")
            .font(fontSettings.rowTitle)
            // The semibold/regular swap on `isRead` shifts row height by a
            // sub-point on the same frame the read state flips. The shift
            // is now hidden by `ContentView`'s yield-then-insert microtask
            // on `pendingReadIDs` (one frame later, off the selection-commit
            // critical path) and any residual reflow is recentred by
            // `EntryListView`'s post-refresh `ScrollViewReader.scrollTo`.
            // Don't drop the weight — it carries the unread/read visual
            // hierarchy the rest of the row design depends on.
            .fontWeight(isRead ? .regular : .semibold)
            .lineLimit(2)
            .foregroundStyle(isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)

          Spacer()

          Text(row.formattedPublishedTime)
            .font(fontSettings.rowFeedName)
            .foregroundStyle(.tertiary)
        }

        if let domain = row.displayDomain, !domain.isEmpty {
          Text(domain.lowercased())
            .font(fontSettings.rowFeedName)
            .foregroundStyle(FontTheme.domainPillColor)
        }

        // Summary excerpt (summary-preferred / plainText fallback, applied at
        // projection time by `rowExcerpt`)
        if !row.excerpt.isEmpty {
          Text(row.excerpt)
            .font(fontSettings.rowSummary)
            .lineLimit(2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 4)
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
