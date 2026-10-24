import AppKit
import SwiftUI

// MARK: - Focused Command Context

/// Single bundle carrying every menu-bar action and enablement flag
/// `ContentView` publishes, behind one `FocusedValueKey`.
struct FeederCommandContext {
  let syncAction: () -> Void
  let markAllReadAction: () -> Void
  /// Opens the search field of the article list and focuses it.
  let findAction: () -> Void
  let toggleViewModeAction: () -> Void
  let toggleFilterAction: () -> Void
  let openInBrowserAction: () -> Void
  let copyLinkAction: () -> Void
  let toggleReadAction: () -> Void
  let moveSelectionDownAction: () -> Void
  let moveSelectionUpAction: () -> Void
  let canMarkAllRead: Bool
  let canOpenInBrowser: Bool
  let hasSelectedEntry: Bool
  /// The read state that the window shows for the selected article, or `nil`
  /// without a selected article.
  let selectedEntryIsRead: Bool?
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

    // A shortcut without the Command modifier reaches the menu only when no
    // responder handled the key: a text field types it, and the per-panel
    // handlers in `KeyHandling.swift` handle it first.

    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Find…") {
        context?.findAction()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(context == nil || context?.hasSidebarSelection != true)
    }

    CommandMenu("Article") {
      // The mark-all-read chord has no confirmation dialog; `KeyHandling.swift`
      // holds that contract.
      Button("Mark All as Read") {
        guard !Self.isShortcutKeyPress("a") else { return }
        context?.markAllReadAction()
      }
      .keyboardShortcut("a", modifiers: .shift)
      .disabled(context == nil || context?.canMarkAllRead != true)

      Button((context?.currentFilter ?? .unread).toggleMenuTitle) {
        guard !Self.isShortcutKeyPress("u") else { return }
        context?.toggleFilterAction()
      }
      .keyboardShortcut("u", modifiers: [])
      .disabled(context == nil || context?.hasSidebarSelection != true)

      Divider()

      Button(context?.selectedEntryIsRead == false ? "Mark as Read" : "Mark as Unread") {
        context?.toggleReadAction()
      }
      .keyboardShortcut("m", modifiers: [])
      .disabled(context?.selectedEntryIsRead == nil)

      Button(context?.currentViewMode == .web ? "Reader Mode" : "Web Mode") {
        context?.toggleViewModeAction()
      }
      .keyboardShortcut("r", modifiers: [])
      .disabled(context == nil || context?.hasSelectedEntry != true)

      Button("Open in Browser") {
        context?.openInBrowserAction()
      }
      .keyboardShortcut("b", modifiers: [])
      .disabled(context == nil || context?.canOpenInBrowser != true)

      Button("Copy Link") {
        context?.copyLinkAction()
      }
      .keyboardShortcut("c", modifiers: [])
      .disabled(context == nil || context?.canOpenInBrowser != true)
    }

    CommandMenu("Navigate") {
      Button("Next Category") {
        context?.moveSelectionDownAction()
      }
      .keyboardShortcut("j", modifiers: [])
      .disabled(context == nil)

      Button("Previous Category") {
        context?.moveSelectionUpAction()
      }
      .keyboardShortcut("k", modifiers: [])
      .disabled(context == nil)
    }
  }

  private static func isShortcutKeyPress(_ key: String) -> Bool {
    isMenuShortcutKeyPress(
      eventType: NSApp.currentEvent?.type, characters: NSApp.currentEvent?.charactersIgnoringModifiers, key: key)
  }
}

/// True when the shortcut key of a menu item, not a click or a keyboard
/// selection in the open menu, chose the item. The U key and the
/// mark-all-read chord act only from the panels whose handlers take them, so a
/// key press that reaches the menu from another surface, such as the article
/// web view, must do nothing.
nonisolated func isMenuShortcutKeyPress(eventType: NSEvent.EventType?, characters: String?, key: String) -> Bool {
  eventType == .keyDown && characters?.lowercased() == key
}
