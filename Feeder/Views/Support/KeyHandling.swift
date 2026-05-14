import SwiftUI

// MARK: - Panel Focus

/// Which split-view column currently owns keyboard focus.
enum PanelFocus: Hashable {
  case sidebar
  case articleList
}

// MARK: - Mark All Read Key Handler

/// Intercepts Shift+A before List type-to-select can capture it.
//
// ⇧A (mark all as read) does not show a confirmation dialog by design:
// the modifier+letter chord is already a two-key gesture and is not
// pressed accidentally. A confirmation would break the calm reading
// flow (vision.md → UX north star). Undo support is the right answer,
// not a dialog.
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

/// Intercepts bare-key shortcuts on each panel's List/view, preventing
/// List type-to-select from consuming them.
//
// Per-panel bare-key dispatcher. Lives on each panel's List so J/K/R/B
// only fire when that List has focus — see ContentView for the rationale
// behind the dual-route design (avoids triggering shortcuts while typing
// in text fields).
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
