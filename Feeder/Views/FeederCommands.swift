import SwiftUI

// MARK: - Focused Command Context

/// Single bundle carrying the model REFERENCES and menu-bar action closures
/// `ContentView` publishes for `FeederCommands` to consume.
///
/// Issue #146 final fix: the context deliberately carries NO enablement
/// booleans. Computing `canMarkAllRead` / `hasSelectedEntry` in
/// `ContentView.body` read the navigation state there, which re-dirtied the
/// whole shell on every selection change and would have silently defeated
/// the pane split. The enablement is computed INSIDE the `FeederCommands`
/// scene body from the carried references, so the Commands scene forms its
/// own Observation dependency on the nav model — the shell publishes
/// references only (holding a reference is not a body read).
struct FeederCommandContext {
  let nav: ReadingSelection
  let syncEngine: SyncEngine
  let classificationEngine: ClassificationEngine
  let syncAction: () -> Void
  let markAllReadAction: () -> Void
  let toggleViewModeAction: () -> Void
  let openInBrowserAction: () -> Void
  let moveSelectionDownAction: () -> Void
  let moveSelectionUpAction: () -> Void
}

private struct FeederCommandContextKey: FocusedValueKey {
  typealias Value = FeederCommandContext
}

extension FocusedValues {
  var feederCommandContext: FeederCommandContext? {
    get { self[FeederCommandContextKey.self] }
    set { self[FeederCommandContextKey.self] = newValue }
  }
}

// MARK: - Focused Values Modifier

/// Publishes the command context on the focused scene. Extracted so
/// ContentView.body does not exceed the type-checker's reasonable-time limit.
struct FocusedValuesModifier: ViewModifier {
  let context: FeederCommandContext

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.feederCommandContext, context)
  }
}

// MARK: - Menu Bar Commands

struct FeederCommands: Commands {
  @FocusedValue(\.feederCommandContext)
  private var context

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("Sync") {
        context?.syncAction()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(context == nil || isSyncing)
    }

    // Bare-key shortcuts (R, B, J, K) are handled via BareKeyHandler
    // applied on each panel's List, so they intercept before type-to-select and
    // don't fire inside modal text fields. Menu items show the key for discoverability.

    CommandMenu("Article") {
      // ⇧A intentionally has no confirmation dialog — see KeyHandling.swift
      // (MarkAllReadKeyHandler) for the rationale.
      Button("Mark All as Read\t ⇧A") {
        context?.markAllReadAction()
      }
      .disabled(context == nil || !canMarkAllRead)

      Divider()

      Button("\(currentViewMode == .web ? "Reader Mode" : "Web Mode")\t R") {
        context?.toggleViewModeAction()
      }
      .disabled(context == nil || !hasSelectedEntry)

      Button("Open in Browser\t B") {
        context?.openInBrowserAction()
      }
      .disabled(context == nil || !hasSelectedEntry)
    }

    CommandMenu("Navigate") {
      Button("Next Category\t J") {
        context?.moveSelectionDownAction()
      }
      .disabled(context == nil)

      Button("Previous Category\t K") {
        context?.moveSelectionUpAction()
      }
      .disabled(context == nil)
    }
  }

  // MARK: - Enablement (computed here so the shell never reads nav state)

  private var canMarkAllRead: Bool {
    guard let nav = context?.nav else { return false }
    return nav.articleFilter == .unread && nav.selection != nil
  }

  /// Also gates "Open in Browser" — both act on the selected entry.
  private var hasSelectedEntry: Bool {
    context?.nav.selectedEntry != nil
  }

  private var isSyncing: Bool {
    guard let context else { return false }
    return context.syncEngine.isSyncing || context.classificationEngine.isClassifying
  }

  private var currentViewMode: ArticleViewMode {
    context?.nav.articleViewMode ?? .web
  }
}
