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
        guard !isTypingInArticleSearch() else { return .ignored }
        action()
        return .handled
      }
  }
}

// MARK: - Detail Page Key Handler

/// The page direction for Space in the article list: Space pages down and
/// Shift-Space pages up. Without a selected article, or with another
/// modifier, the key is not a page key.
func detailPageDirection(hasSelectedEntry: Bool, modifiers: EventModifiers) -> DetailPageDirection? {
  guard hasSelectedEntry else { return nil }
  switch modifiers.subtracting(.capsLock) {
  case []: return .down
  case .shift: return .up
  default: return nil
  }
}

/// Pages the detail pane with Space and Shift-Space. It must stay on the
/// article list itself, so focus stays in the list, a text field keeps Space,
/// and `List` type-to-select cannot consume the key.
struct DetailPageKeyHandler: ViewModifier {
  let action: (EventModifiers) -> KeyPress.Result

  func body(content: Content) -> some View {
    content
      .onKeyPress(keys: [.space], phases: [.down, .repeat]) { press in
        isTypingInArticleSearch() ? .ignored : action(press.modifiers)
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
  var onM: () -> KeyPress.Result = { .handled }
  var onC: () -> KeyPress.Result = { .handled }
  var onU: () -> KeyPress.Result = { .handled }
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
  /// True on the sidebar and the article list. U switches the filter only
  /// from these two panels.
  var handlesFilterKey = false
  @Environment(\.bareKeyActions)
  private var actions

  func body(content: Content) -> some View {
    content
      .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in isTypingInArticleSearch() ? .ignored : actions.onJ() }
      .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in isTypingInArticleSearch() ? .ignored : actions.onK() }
      .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in isTypingInArticleSearch() ? .ignored : actions.onR() }
      .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in isTypingInArticleSearch() ? .ignored : actions.onB() }
      .onKeyPress(characters: CharacterSet(charactersIn: "mM")) { _ in isTypingInArticleSearch() ? .ignored : actions.onM() }
      .onKeyPress(characters: CharacterSet(charactersIn: "cC")) { _ in isTypingInArticleSearch() ? .ignored : actions.onC() }
      .onKeyPress(characters: CharacterSet(charactersIn: "uU")) { _ in
        handlesFilterKey && !isTypingInArticleSearch() ? actions.onU() : .ignored
      }
  }
}
