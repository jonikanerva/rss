import AppKit
import Testing

@testable import Feeder

/// The U key and the mark-all-read chord must do nothing when they reach the
/// menu, but a click or a keyboard selection in the open menu must still act.
struct MenuShortcutKeyPressTests {
  @Test
  func theShortcutKeyIsAShortcutKeyPress() {
    #expect(isMenuShortcutKeyPress(eventType: .keyDown, characters: "u", key: "u"))
    #expect(isMenuShortcutKeyPress(eventType: .keyDown, characters: "A", key: "a"))
  }

  @Test
  func aClickOrAMenuSelectionIsNotAShortcutKeyPress() {
    #expect(!isMenuShortcutKeyPress(eventType: .leftMouseUp, characters: nil, key: "u"))
    #expect(!isMenuShortcutKeyPress(eventType: .keyDown, characters: "\r", key: "u"))
    #expect(!isMenuShortcutKeyPress(eventType: .keyDown, characters: " ", key: "a"))
    #expect(!isMenuShortcutKeyPress(eventType: nil, characters: nil, key: "u"))
  }
}
