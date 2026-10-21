import Testing

@testable import Feeder

/// The U key and the Article menu command switch between the two filters, and
/// the menu title names the filter that the command shows.
@MainActor
struct ArticleFilterTests {
  @Test
  func toggledSwitchesToTheOtherFilter() {
    #expect(ArticleFilter.unread.toggled == .read)
    #expect(ArticleFilter.read.toggled == .unread)
  }

  @Test
  func menuTitleNamesTheFilterThatTheCommandShows() {
    #expect(ArticleFilter.unread.toggleMenuTitle == "Show Read Articles\t U")
    #expect(ArticleFilter.read.toggleMenuTitle == "Show Unread Articles\t U")
  }
}
