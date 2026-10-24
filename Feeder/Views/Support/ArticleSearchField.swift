import SwiftUI

/// The search state of one main window. `ContentView` keeps one instance and
/// reads only `term` in its body, so typing re-renders the search field and
/// not the window. Nothing here is persisted.
@Observable
final class ArticleSearchState {
  /// The text of the search field. It stays when the sidebar selection
  /// changes.
  var text = ""
  var isPresented = false
  /// The term that narrows the article list: `text` after the typing pause.
  private(set) var term: ArticleSearchTerm?

  /// The term that the field holds now, also before the typing pause ends.
  /// Mark All as Read uses it, so the write follows what the user typed.
  var typedTerm: ArticleSearchTerm? { ArticleSearchTerm(text) }

  func commitTypedTerm() {
    let typed = typedTerm
    if typed != term { term = typed }
  }
}

/// The search field of the article list, in the toolbar of the article-list
/// column, with its typing pause and its focus rules.
struct ArticleSearchField: ViewModifier {
  @Bindable
  var state: ArticleSearchState
  var isFocused: FocusState<Bool>.Binding
  /// Return in the field moves focus to the article list.
  let onSubmit: () -> Void
  /// The field closed: focus returns to the article list.
  let onDismiss: () -> Void

  static let debounce: Duration = .milliseconds(200)

  func body(content: Content) -> some View {
    content
      .searchable(text: $state.text, isPresented: $state.isPresented, placement: .toolbar, prompt: "Search")
      .searchFocused(isFocused)
      .onSubmit(of: .search) {
        state.commitTypedTerm()
        onSubmit()
      }
      .task(id: state.text) {
        // A cleared field commits at once.
        if state.typedTerm != nil {
          try? await Task.sleep(for: Self.debounce)
          guard !Task.isCancelled else { return }
        }
        state.commitTypedTerm()
      }
      .onChange(of: state.isPresented) { _, isPresented in
        if !isPresented { onDismiss() }
      }
  }
}
