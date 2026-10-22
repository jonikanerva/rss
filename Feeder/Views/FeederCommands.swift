import SwiftUI

// MARK: - Focused Command Context

/// Single bundle carrying every menu-bar action and enablement flag
/// `ContentView` publishes, behind one `FocusedValueKey`.
struct FeederCommandContext {
  let syncAction: () -> Void
  let markAllReadAction: () -> Void
  let toggleViewModeAction: () -> Void
  let toggleFilterAction: () -> Void
  let openInBrowserAction: () -> Void
  let copyLinkAction: () -> Void
  let moveSelectionDownAction: () -> Void
  let moveSelectionUpAction: () -> Void
  let canMarkAllRead: Bool
  let canOpenInBrowser: Bool
  let hasSelectedEntry: Bool
  let isSyncing: Bool
  let currentViewMode: ArticleViewMode
  let currentFilter: ArticleFilter
  let hasSidebarSelection: Bool
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

/// Publishes the command context on the focused scene. Extracted, so
/// `ContentView.body` stays inside the type-checker's limit.
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
  @Environment(\.openWindow)
  private var openWindow

  var body: some Commands {
    // Feeder has one main window: replacing this group removes File → New
    // Window. Window → Feeder and a click on the Dock icon reopen it.
    CommandGroup(replacing: .newItem) {
      Button("Sync") {
        context?.syncAction()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(context == nil || context?.isSyncing == true)
    }

    CommandGroup(after: .singleWindowList) {
      // The value form brings the open main window to the front. Without the
      // value, `openWindow` creates a second main window (`MainWindow`).
      Button("Feeder") {
        openWindow(id: MainWindow.sceneID, value: MainWindow.main)
      }
      .keyboardShortcut("0", modifiers: .command)
    }

    // The bare-key shortcuts are handled per panel, so they intercept before
    // type-to-select and never fire inside a text field. These menu items show
    // the key for discoverability only.

    CommandMenu("Article") {
      // The mark-all-read chord has no confirmation dialog; `KeyHandling.swift`
      // holds that contract.
      Button("Mark All as Read\t ⇧A") {
        context?.markAllReadAction()
      }
      .disabled(context == nil || context?.canMarkAllRead != true)

      Button((context?.currentFilter ?? .unread).toggleMenuTitle) {
        context?.toggleFilterAction()
      }
      .disabled(context == nil || context?.hasSidebarSelection != true)

      Divider()

      Button("\(context?.currentViewMode == .web ? "Reader Mode" : "Web Mode")\t R") {
        context?.toggleViewModeAction()
      }
      .disabled(context == nil || context?.hasSelectedEntry != true)

      Button("Open in Browser\t B") {
        context?.openInBrowserAction()
      }
      .disabled(context == nil || context?.canOpenInBrowser != true)

      Button("Copy Link") {
        context?.copyLinkAction()
      }
      .disabled(context == nil || context?.canOpenInBrowser != true)
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
}
