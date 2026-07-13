import Foundation
import SwiftData
import SwiftUI

// MARK: - Reading Selection (navigation state owner, issue #146 final fix)

/// Owner of the volatile navigation state for the three-pane reading flow:
/// the sidebar selection, the article-list selection, the memoized live
/// `Entry`, the read filter, and the article view mode.
///
/// Extracted from `ContentView` `@State` so navigation state is READ only by
/// the pane that renders it — `ContentView.body` stops re-evaluating (and
/// rebuilding the sidebar DTOs + the whole `NavigationSplitView` shell) on
/// every category/selection switch, which the #146 diagnosis measured as an
/// N-independent ~700 ms stall. A view forms an Observation dependency only
/// when its BODY reads a tracked property — holding or passing the reference
/// does not
/// (`developer.apple.com/documentation/swiftui/managing-model-data-in-your-app`)
/// — so `ContentView` holds this as `@State` and injects it via
/// `.environment` without depending on it.
@MainActor
@Observable
final class ReadingSelection {
  /// Sidebar selection — what the content column shows. `SidebarInner`
  /// binds the List highlight via `@Bindable` (a binding is not a body READ,
  /// so the sidebar's DTO construction gains no dependency on it).
  var selection: SidebarSelection?
  /// Article-list selection (issue #148): the row DTO's
  /// `PersistentIdentifier`, written by the `List` selection binding,
  /// Tab-into-list, the Escape / filter / sidebar clears, mark-all-read, and
  /// the perf runner.
  var selectedEntryID: PersistentIdentifier?
  /// Memoized live model for the selected row — the ONE full `Entry`
  /// materialization per selection (detail pane, open-in-browser, mark-read,
  /// drain keys, pinned-row id). SINGLE-WRITER discipline (issue #148), now
  /// COMPILER-ENFORCED via `private(set)`: `resolveSelectedEntry(in:)` is
  /// the only writer, called from EXACTLY ONE site — `ContentPane`'s
  /// `.onChange(of: nav.selectedEntryID)`. Every other consumer only reads.
  private(set) var selectedEntry: Entry?
  var articleFilter: ArticleFilter = .unread
  var articleViewMode: ArticleViewMode = .web

  // MARK: - Taxonomy mirrors (DERIVED state — SidebarPane is the SOLE writer)

  /// Visible sidebar rows in keyboard order (collapsed folders' children
  /// excluded). DERIVED state: `SidebarPane` — the sole owner of the
  /// taxonomy `@Query`s — is the SOLE writer, via
  /// `updateTaxonomy(items:displayNames:)` on every taxonomy / collapse
  /// change. Mirrored here so J/K moves and the invalid-selection fallback
  /// never read `@Model` rows.
  private(set) var sidebarItems: [SidebarSelection] = []
  /// Display name per selectable sidebar item. Covers EVERY folder and
  /// category (not just the visible rows) so `revalidateSelection()` keeps
  /// its exact pre-split semantics — a selection inside a collapsed folder
  /// stays valid. Keyed by `SidebarSelection` so the folder and category
  /// label namespaces stay distinct for both existence checks and the
  /// `ContentPane.navigationTitle` dictionary lookup (zero `@Model` reads).
  /// DERIVED state with the same sole writer as `sidebarItems`.
  private(set) var displayNames: [SidebarSelection: String] = [:]

  // MARK: - Writers

  /// SOLE taxonomy-mirror writer — called by `SidebarPane` only, from its
  /// taxonomy-change `.onChange`. Everything here is derived from
  /// `SidebarPane`'s queries; no other surface may write the mirrors.
  func updateTaxonomy(
    items: [SidebarSelection], displayNames: [SidebarSelection: String]
  ) {
    sidebarItems = items
    self.displayNames = displayNames
  }

  /// Resolve the memoized `selectedEntry` for the current `selectedEntryID`
  /// — the ONLY `selectedEntry` writer (see the property doc). No-ops when
  /// the memo already matches. Also resets the article view mode to `.web`,
  /// the single owner of that per-selection-commit reset. The model never
  /// HOLDS a `ModelContext`; the caller passes the MainActor context in at
  /// the interface↔store boundary — an O(1) primary-key lookup for exactly
  /// one row.
  func resolveSelectedEntry(in context: ModelContext) {
    guard selectedEntryID != selectedEntry?.persistentModelID else { return }
    selectedEntry = selectedEntryID.flatMap { context.model(for: $0) as? Entry }
    articleViewMode = .web
  }

  // MARK: - Pure navigation transforms (mirror-backed, container-free tests)

  /// Move the sidebar selection by `offset` in visible keyboard order.
  /// Pre-split `ContentView.moveSidebarSelection` semantics verbatim,
  /// including the nil-selection first/last fallback and index clamping —
  /// now over the mirror, so a J/K keystroke reads zero `@Model` rows.
  func moveSelection(by offset: Int) {
    let items = sidebarItems
    guard !items.isEmpty else { return }
    guard let current = selection, let index = items.firstIndex(of: current) else {
      selection = offset > 0 ? items.first : items.last
      return
    }
    let newIndex = min(max(index + offset, 0), items.count - 1)
    selection = items[newIndex]
  }

  /// Drop a selection whose folder / category no longer exists and fall back
  /// to the first visible category. Pre-split
  /// `ContentView.revalidateSelection` semantics verbatim: existence is
  /// checked against ALL taxonomy labels (`displayNames`), not just the
  /// visible rows, so a selection inside a collapsed folder survives.
  func revalidateSelection() {
    switch selection {
    case .folder(let label) where displayNames[.folder(label)] == nil:
      selection = nil
    case .category(let label) where displayNames[.category(label)] == nil:
      selection = nil
    default:
      break
    }
    if selection == nil {
      selection = sidebarItems.first { $0.isCategory }
    }
  }
}
