import AppKit
import Testing

@testable import Feeder

// MARK: - bareKeyRoute truth table

/// Truth table for the pure bare-key classifier behind
/// `BareKeyForwardingWebView.keyDown(with:)` (ArticleWebView.swift). The
/// classifier decides which keypresses inside the article web view route to
/// `BareKeyActions` and which fall through to the web view itself.
struct BareKeyRoutingTests {
  @Test
  func lowercaseBareKeysRoute() {
    #expect(bareKeyRoute(characters: "j", modifiers: []) == .j)
    #expect(bareKeyRoute(characters: "k", modifiers: []) == .k)
    #expect(bareKeyRoute(characters: "r", modifiers: []) == .r)
    #expect(bareKeyRoute(characters: "b", modifiers: []) == .b)
    #expect(bareKeyRoute(characters: "m", modifiers: []) == .m)
    #expect(bareKeyRoute(characters: "c", modifiers: []) == .c)
  }

  @Test
  func shiftedUppercaseKeysRoute() {
    #expect(bareKeyRoute(characters: "J", modifiers: .shift) == .j)
    #expect(bareKeyRoute(characters: "K", modifiers: .shift) == .k)
    #expect(bareKeyRoute(characters: "R", modifiers: .shift) == .r)
    #expect(bareKeyRoute(characters: "B", modifiers: .shift) == .b)
    #expect(bareKeyRoute(characters: "M", modifiers: .shift) == .m)
    #expect(bareKeyRoute(characters: "C", modifiers: .shift) == .c)
  }

  @Test
  func uppercaseWithoutShiftRoutes() {
    // Caps Lock produces uppercase characters with no shift flag.
    #expect(bareKeyRoute(characters: "R", modifiers: []) == .r)
    #expect(bareKeyRoute(characters: "B", modifiers: .capsLock) == .b)
  }

  @Test
  func commandOptionControlModifiersNeverRoute() {
    let blocking: [NSEvent.ModifierFlags] = [
      .command, .option, .control,
      [.command, .shift], [.option, .shift], [.control, .shift],
      [.command, .option, .control],
    ]
    for modifiers in blocking {
      #expect(bareKeyRoute(characters: "r", modifiers: modifiers) == nil)
      #expect(bareKeyRoute(characters: "j", modifiers: modifiers) == nil)
    }
  }

  @Test
  func nonShortcutLettersDoNotRoute() {
    // ⇧A (mark all read) is deliberately NOT forwarded from the web view.
    #expect(bareKeyRoute(characters: "A", modifiers: .shift) == nil)
    #expect(bareKeyRoute(characters: "a", modifiers: []) == nil)
    #expect(bareKeyRoute(characters: "x", modifiers: []) == nil)
    // U switches the filter only from the sidebar and the article list.
    #expect(bareKeyRoute(characters: "u", modifiers: []) == nil)
  }

  @Test
  func scrollingAndNavigationKeysFallThrough() {
    // Space, arrows (function-key code points with the .function flag),
    // Tab, and Escape must reach the web view untouched.
    #expect(bareKeyRoute(characters: " ", modifiers: []) == nil)
    #expect(bareKeyRoute(characters: "\u{F700}", modifiers: .function) == nil)
    #expect(bareKeyRoute(characters: "\u{F701}", modifiers: .function) == nil)
    #expect(bareKeyRoute(characters: "\t", modifiers: []) == nil)
    #expect(bareKeyRoute(characters: "\u{1B}", modifiers: []) == nil)
  }

  @Test
  func emptyNilAndMultiCharacterStringsDoNotRoute() {
    #expect(bareKeyRoute(characters: nil, modifiers: []) == nil)
    #expect(bareKeyRoute(characters: "", modifiers: []) == nil)
    #expect(bareKeyRoute(characters: "rr", modifiers: []) == nil)
    #expect(bareKeyRoute(characters: "é", modifiers: []) == nil)
  }
}
