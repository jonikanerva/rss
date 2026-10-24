import AppKit
import SwiftUI

/// The search field of the article list, in the toolbar of the article-list
/// column. The system collapses the field to a magnifier button when the
/// toolbar is narrow.
struct ArticleSearchField: ViewModifier {
  @Binding
  var text: String
  @Binding
  var isPresented: Bool
  var isFocused: FocusState<Bool>.Binding
  /// Return in the field moves focus to the article list.
  let onSubmit: () -> Void

  func body(content: Content) -> some View {
    content
      .searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: "Search")
      .searchFocused(isFocused)
      .onSubmit(of: .search, onSubmit)
  }
}

/// The window-level search behaviour: ⌘F, the typing debounce, and the
/// focus return when the search field closes.
struct ArticleSearchLifecycle: ViewModifier {
  let searchText: String
  let isSearchPresented: Bool
  /// Edit → Find → Find… (⌘F) from a panel that does not handle the find
  /// command itself.
  let onFind: () -> Void
  /// Receives the term after a pause in typing. A cleared field commits nil at
  /// once.
  let onCommit: (ArticleSearchTerm?) -> Void
  let onDismiss: () -> Void

  static let debounce: Duration = .milliseconds(200)

  func body(content: Content) -> some View {
    content
      .onCommand(#selector(NSResponder.performTextFinderAction(_:)), perform: onFind)
      .onCommand(#selector(NSTextView.performFindPanelAction(_:)), perform: onFind)
      .task(id: searchText) {
        let term = ArticleSearchTerm(searchText)
        if term != nil {
          try? await Task.sleep(for: Self.debounce)
          guard !Task.isCancelled else { return }
        }
        onCommit(term)
      }
      .onChange(of: isSearchPresented) { _, isPresented in
        if !isPresented { onDismiss() }
      }
  }
}
