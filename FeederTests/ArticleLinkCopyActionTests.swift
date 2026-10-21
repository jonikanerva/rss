import Foundation
import Testing

@testable import Feeder

/// Edit → Copy in the article list copies the link of the selected article.
/// The tests inject the write, so no test touches the general pasteboard.
@MainActor
struct ArticleLinkCopyActionTests {
  @Test
  func noSelectedLinkDisablesCopy() {
    #expect(articleLinkCopyAction(url: nil) { _ in Issue.record("unexpected write") } == nil)
  }

  @Test
  func copyWritesTheSelectedLinkOnce() throws {
    let url = try #require(URL(string: "https://example.com/articles/42"))
    var written: [URL] = []

    let action = try #require(articleLinkCopyAction(url: url) { written.append($0) })
    #expect(written.isEmpty)
    action()

    #expect(written == [url])
  }
}
