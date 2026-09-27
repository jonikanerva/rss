import AppKit
import Testing

@testable import Feeder

/// `NSPasteboard.writeLink(_:)` on a pasteboard with a unique name. No test
/// touches the general pasteboard: the test host is the real app, and a
/// programmatic read of the general pasteboard shows a system privacy alert.
@MainActor
@Suite("Pasteboard link writing")
struct PasteboardLinkTests {
  private static let privateType = NSPasteboard.PasteboardType("com.feeder.tests.old-contents")

  /// Run `body` with a new unique pasteboard that holds two old items, and
  /// release the pasteboard afterwards.
  private func withOldContents(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    let first = NSPasteboardItem()
    first.setString("old text", forType: .string)
    let second = NSPasteboardItem()
    second.setString("old private value", forType: Self.privateType)
    pasteboard.writeObjects([first, second])
    try body(pasteboard)
  }

  private func link() throws -> URL {
    try #require(URL(string: "https://example.com/articles/42?ref=feed#top"))
  }

  @Test("the link replaces the old contents with exactly one item")
  func linkReplacesOldContents() throws {
    try withOldContents { pasteboard in
      try #require(pasteboard.pasteboardItems?.count == 2)

      pasteboard.writeLink(try link())

      let items = try #require(pasteboard.pasteboardItems)
      #expect(items.count == 1)
      #expect(pasteboard.availableType(from: [Self.privateType]) == nil)
    }
  }

  @Test("the item carries the link as a URL and as plain text")
  func itemCarriesURLAndPlainText() throws {
    try withOldContents { pasteboard in
      let url = try link()

      pasteboard.writeLink(url)

      let item = try #require(pasteboard.pasteboardItems?.first)
      #expect(item.string(forType: .URL) == url.absoluteString)
      #expect(item.string(forType: .string) == url.absoluteString)
    }
  }

  @Test("a URL read returns the link")
  func urlReadReturnsLink() throws {
    try withOldContents { pasteboard in
      let url = try link()

      pasteboard.writeLink(url)

      let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
      #expect(urls == [url])
    }
  }
}
