import SwiftUI

// MARK: - Focused Value Keys

private struct SyncActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct MarkAllReadActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct ToggleViewModeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct OpenInBrowserActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct MoveSelectionDownActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct MoveSelectionUpActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct CanMarkAllReadKey: FocusedValueKey {
  typealias Value = Bool
}

private struct CanOpenInBrowserKey: FocusedValueKey {
  typealias Value = Bool
}

private struct HasSelectedEntryKey: FocusedValueKey {
  typealias Value = Bool
}

private struct IsSyncingKey: FocusedValueKey {
  typealias Value = Bool
}

private struct CurrentViewModeKey: FocusedValueKey {
  typealias Value = ArticleViewMode
}

extension FocusedValues {
  var syncAction: (() -> Void)? {
    get { self[SyncActionKey.self] }
    set { self[SyncActionKey.self] = newValue }
  }

  var markAllReadAction: (() -> Void)? {
    get { self[MarkAllReadActionKey.self] }
    set { self[MarkAllReadActionKey.self] = newValue }
  }

  var toggleViewModeAction: (() -> Void)? {
    get { self[ToggleViewModeActionKey.self] }
    set { self[ToggleViewModeActionKey.self] = newValue }
  }

  var openInBrowserAction: (() -> Void)? {
    get { self[OpenInBrowserActionKey.self] }
    set { self[OpenInBrowserActionKey.self] = newValue }
  }

  var moveSelectionDownAction: (() -> Void)? {
    get { self[MoveSelectionDownActionKey.self] }
    set { self[MoveSelectionDownActionKey.self] = newValue }
  }

  var moveSelectionUpAction: (() -> Void)? {
    get { self[MoveSelectionUpActionKey.self] }
    set { self[MoveSelectionUpActionKey.self] = newValue }
  }

  var canMarkAllRead: Bool? {
    get { self[CanMarkAllReadKey.self] }
    set { self[CanMarkAllReadKey.self] = newValue }
  }

  var canOpenInBrowser: Bool? {
    get { self[CanOpenInBrowserKey.self] }
    set { self[CanOpenInBrowserKey.self] = newValue }
  }

  var hasSelectedEntry: Bool? {
    get { self[HasSelectedEntryKey.self] }
    set { self[HasSelectedEntryKey.self] = newValue }
  }

  var isSyncing: Bool? {
    get { self[IsSyncingKey.self] }
    set { self[IsSyncingKey.self] = newValue }
  }

  var currentViewMode: ArticleViewMode? {
    get { self[CurrentViewModeKey.self] }
    set { self[CurrentViewModeKey.self] = newValue }
  }
}

// MARK: - Focused Values Modifier

/// Publishes all focused scene values for menu bar commands.
/// Extracted from ContentView body to keep the expression type-checkable.
struct FocusedValuesModifier: ViewModifier {
  let syncAction: () -> Void
  let markAllReadAction: () -> Void
  let toggleViewModeAction: () -> Void
  let openInBrowserAction: () -> Void
  let moveSelectionDownAction: () -> Void
  let moveSelectionUpAction: () -> Void
  let canMarkAllRead: Bool
  let canOpenInBrowser: Bool
  let hasSelectedEntry: Bool
  let isSyncing: Bool
  let currentViewMode: ArticleViewMode

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.syncAction, syncAction)
      .focusedSceneValue(\.markAllReadAction, markAllReadAction)
      .focusedSceneValue(\.toggleViewModeAction, toggleViewModeAction)
      .focusedSceneValue(\.openInBrowserAction, openInBrowserAction)
      .focusedSceneValue(\.moveSelectionDownAction, moveSelectionDownAction)
      .focusedSceneValue(\.moveSelectionUpAction, moveSelectionUpAction)
      .focusedSceneValue(\.canMarkAllRead, canMarkAllRead)
      .focusedSceneValue(\.canOpenInBrowser, canOpenInBrowser)
      .focusedSceneValue(\.hasSelectedEntry, hasSelectedEntry)
      .focusedSceneValue(\.isSyncing, isSyncing)
      .focusedSceneValue(\.currentViewMode, currentViewMode)
  }
}

// MARK: - Menu Bar Commands

struct FeederCommands: Commands {
  @FocusedValue(\.syncAction)
  private var syncAction
  @FocusedValue(\.markAllReadAction)
  private var markAllReadAction
  @FocusedValue(\.toggleViewModeAction)
  private var toggleViewModeAction
  @FocusedValue(\.openInBrowserAction)
  private var openInBrowserAction
  @FocusedValue(\.moveSelectionDownAction)
  private var moveSelectionDown
  @FocusedValue(\.moveSelectionUpAction)
  private var moveSelectionUp
  @FocusedValue(\.canMarkAllRead)
  private var canMarkAllRead
  @FocusedValue(\.canOpenInBrowser)
  private var canOpenInBrowser
  @FocusedValue(\.hasSelectedEntry)
  private var hasSelectedEntry
  @FocusedValue(\.isSyncing)
  private var isSyncing
  @FocusedValue(\.currentViewMode)
  private var currentViewMode

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("Sync") {
        syncAction?()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(syncAction == nil || isSyncing == true)
    }

    CommandMenu("Article") {
      Button("Mark All as Read") {
        markAllReadAction?()
      }
      .keyboardShortcut("a", modifiers: .shift)
      .disabled(markAllReadAction == nil || canMarkAllRead != true)

      Divider()

      Button(currentViewMode == .web ? "Reader Mode" : "Web Mode") {
        toggleViewModeAction?()
      }
      .keyboardShortcut("r", modifiers: [])
      .disabled(toggleViewModeAction == nil || hasSelectedEntry != true)

      Button("Open in Browser") {
        openInBrowserAction?()
      }
      .keyboardShortcut("b", modifiers: [])
      .disabled(openInBrowserAction == nil || canOpenInBrowser != true)
    }

    CommandMenu("Navigate") {
      Button("Next Category") {
        moveSelectionDown?()
      }
      .keyboardShortcut("j", modifiers: [])
      .disabled(moveSelectionDown == nil)

      Button("Previous Category") {
        moveSelectionUp?()
      }
      .keyboardShortcut("k", modifiers: [])
      .disabled(moveSelectionUp == nil)
    }
  }
}
