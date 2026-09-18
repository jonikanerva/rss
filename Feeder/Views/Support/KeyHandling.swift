import SwiftUI

// MARK: - Panel Focus

/// Which split-view column currently owns keyboard focus.
enum PanelFocus: Hashable {
  case sidebar
  case articleList
}

// MARK: - Mark All Read Key Handler

/// Intercepts the mark-all-read chord before `List` type-to-select captures it.
///
/// The chord shows no confirmation dialog on purpose: a modifier-and-letter
/// gesture is not pressed by accident, and a dialog would break the calm
/// reading flow (`VISION.md → Core Principles`). Undo is the right answer here,
/// not a dialog.
struct MarkAllReadKeyHandler: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .onKeyPress(characters: CharacterSet(charactersIn: "A")) { _ in
        action()
        return .handled
      }
  }
}

// MARK: - Bare Key Actions Environment

/// Actions for bare-key shortcuts that must fire from any panel,
/// intercepting before List type-to-select consumes letter keys.
/// Returns `KeyPress.Result` so individual actions can decline handling.
struct BareKeyActions {
  var onJ: () -> KeyPress.Result = { .handled }
  var onK: () -> KeyPress.Result = { .handled }
  var onR: () -> KeyPress.Result = { .handled }
  var onB: () -> KeyPress.Result = { .handled }
}

private struct BareKeyActionsKey: EnvironmentKey {
  static let defaultValue = BareKeyActions()
}

extension EnvironmentValues {
  var bareKeyActions: BareKeyActions {
    get { self[BareKeyActionsKey.self] }
    set { self[BareKeyActionsKey.self] = newValue }
  }
}

/// Intercepts the bare-key shortcuts on each panel, so `List` type-to-select
/// cannot consume them. It must stay on the panel's own list, so a shortcut
/// fires only while that list has focus and never while the user types in a
/// text field. `ContentView` documents the three routes together.
struct BareKeyHandler: ViewModifier {
  @Environment(\.bareKeyActions)
  private var actions

  func body(content: Content) -> some View {
    content
      .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in actions.onJ() }
      .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in actions.onK() }
      .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in actions.onR() }
      .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in actions.onB() }
  }
}
