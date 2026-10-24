import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Pins the keys of the article search field on a real `NSSearchField` in an
/// offscreen window. In the app, the window-level Escape handler runs first and
/// closes the bar through `isEditingArticleSearch(in:)`; the delegate path
/// covers a window with no such handler.
@MainActor
@Suite("Article search field keys")
struct ArticleSearchFieldKeyTests {
  private final class Calls {
    var cancel = 0
    var submit = 0
  }

  /// The field holds its delegate weakly; SwiftUI keeps the coordinator, so
  /// the test keeps it too.
  private func focusedField(
    text: String, calls: Calls
  ) throws -> (NSWindow, ArticleSearchTextField.Coordinator) {
    let parent = ArticleSearchTextField(
      text: .constant(text), focusRequest: 0,
      onSubmit: { calls.submit += 1 }, onCancel: { calls.cancel += 1 })
    let coordinator = parent.makeCoordinator()
    let field = ArticleSearchTextField.makeField(coordinator: coordinator)
    field.stringValue = text
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = field
    #expect(window.makeFirstResponder(field))
    return (window, coordinator)
  }

  private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: keyCode))
    window.sendEvent(event)
  }

  @Test("Escape closes the bar with text and with an empty field", arguments: ["", "swift"])
  func escapeCancels(text: String) throws {
    let calls = Calls()
    let (window, coordinator) = try focusedField(text: text, calls: calls)
    defer { withExtendedLifetime(coordinator) { window.close() } }
    try press("\u{1b}", keyCode: 53, in: window)
    #expect(calls.cancel >= 1)
  }

  @Test("Return moves focus to the list")
  func returnSubmits() throws {
    let calls = Calls()
    let (window, coordinator) = try focusedField(text: "swift", calls: calls)
    defer { withExtendedLifetime(coordinator) { window.close() } }
    try press("\r", keyCode: 36, in: window)
    #expect(calls.submit == 1)
    #expect(calls.cancel == 0)
  }

  @Test("The window-level Escape handler sees a focused search field")
  func editingStateFollowsFocus() throws {
    let calls = Calls()
    let (window, coordinator) = try focusedField(text: "", calls: calls)
    defer { withExtendedLifetime(coordinator) { window.close() } }
    #expect(isEditingArticleSearch(in: window))
    window.makeFirstResponder(nil)
    #expect(!isEditingArticleSearch(in: window))
  }
}
