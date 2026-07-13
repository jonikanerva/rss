import SwiftUI

// MARK: - Detail Pane (issue #146 final fix)

/// The detail column: renders the memoized selected entry. Reads
/// `nav.selectedEntry` / `nav.articleViewMode` in ITS body, so an article
/// selection re-renders this pane (correct — the article changed) without
/// re-evaluating the `NavigationSplitView` shell, and a CATEGORY switch that
/// clears the selection re-renders only this pane's empty state.
struct DetailPane: View {
  let onMarkAllRead: () -> Void
  let onToggleViewMode: () -> Void
  let onOpenInBrowser: () -> Void

  @Environment(ReadingSelection.self)
  private var nav

  var body: some View {
    Group {
      if let entry = nav.selectedEntry {
        EntryDetailView(entry: entry, viewMode: nav.articleViewMode)
      } else {
        ContentUnavailableView {
          Label("Select an Article", systemImage: "doc.text")
        } description: {
          Text("Choose an article from the list to read it.")
        }
      }
    }
    .modifier(BareKeyHandler())
    .modifier(MarkAllReadKeyHandler(action: onMarkAllRead))
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          onToggleViewMode()
        } label: {
          Label(
            nav.articleViewMode == .web ? "Reader Mode" : "Web Mode",
            systemImage: nav.articleViewMode == .web ? "doc.plaintext" : "doc.richtext"
          )
        }
        .help(
          nav.articleViewMode == .web
            ? "Switch to reader mode (R)" : "Switch to web mode (R)"
        )
        .disabled(nav.selectedEntry == nil)
      }
      ToolbarItem(placement: .automatic) {
        Button {
          onOpenInBrowser()
        } label: {
          Label("Open in Browser", systemImage: "safari")
        }
        .help("Open in browser (B)")
        .disabled(nav.selectedEntry == nil)
      }
    }
  }
}
