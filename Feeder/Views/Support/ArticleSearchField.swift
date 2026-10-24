import AppKit
import SwiftUI

/// The search state of one main window. `ContentView` reads only `term` and
/// `isPresented` in its body, so typing re-renders the search bar and not the
/// window. Nothing here is persisted.
@Observable
final class ArticleSearchState {
  /// The text of the search field. It stays when the sidebar selection
  /// changes.
  var text = ""
  /// Whether the search bar shows above the article list.
  private(set) var isPresented = false
  /// A change asks the search field to take keyboard focus.
  private(set) var focusRequest = 0
  /// The term that narrows the article list: `text` after the typing pause.
  private(set) var term: ArticleSearchTerm?

  /// The term that the field holds now, also before the typing pause ends.
  /// Mark All as Read uses it, so the write follows what the user typed.
  var typedTerm: ArticleSearchTerm? { ArticleSearchTerm(text) }

  /// Show the bar and focus its field.
  func open() {
    isPresented = true
    focusRequest &+= 1
  }

  /// Clear the term at once and hide the bar.
  func close() {
    text = ""
    term = nil
    isPresented = false
  }

  func commitTypedTerm() {
    let typed = typedTerm
    if typed != term { term = typed }
  }
}

/// The search bar at the top of the article-list column. It shows while the
/// search is open, so the narrowed list always shows its term.
struct ArticleSearchBar: View {
  @Bindable
  var state: ArticleSearchState
  /// Return or Down Arrow in the field moves focus to the article list.
  let onSubmit: () -> Void
  /// Escape in the field: the bar closed, so focus returns to the article list.
  let onCancel: () -> Void

  static let debounce: Duration = .milliseconds(200)

  var body: some View {
    VStack(spacing: 0) {
      ArticleSearchTextField(
        text: $state.text, focusRequest: state.focusRequest,
        onSubmit: {
          state.commitTypedTerm()
          onSubmit()
        },
        onCancel: {
          state.close()
          onCancel()
        }
      )
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      Divider()
    }
    .task(id: state.text) {
      // A cleared field commits at once.
      if state.typedTerm != nil {
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return }
      }
      state.commitTypedTerm()
    }
  }
}

/// `NSSearchField` adapter: SwiftUI has no inline search field on macOS, and
/// `searchable` places its field in the window toolbar.
private struct ArticleSearchTextField: NSViewRepresentable {
  @Binding
  var text: String
  let focusRequest: Int
  let onSubmit: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search"
    field.delegate = context.coordinator
    field.setAccessibilityIdentifier("article.search")
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    guard context.coordinator.handledFocusRequest != focusRequest else { return }
    context.coordinator.handledFocusRequest = focusRequest
    // A new field joins its window after this update, so focus waits one turn.
    Task { @MainActor in
      field.window?.makeFirstResponder(field)
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: ArticleSearchTextField
    var handledFocusRequest: Int?

    init(_ parent: ArticleSearchTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onCancel()
        return true
      default:
        return false
      }
    }
  }
}
